#!/usr/bin/env python3
"""
test_usage_upload.py — OFFLINE proof for Phase E1 (reader -> POST /v1/usage wire).

NO live server is touched. It proves, end to end and locally:
  • the client builds the server-shaped summary from a real jsonl scan;
  • the sealed payload round-trips through the SAME Fernet wire format, and (ONLY
    when a server checkout is supplied out-of-band via the TOKENIZER_SERVER_DIR
    env var) the decrypted object is cross-checked against the real server-side
    content firewall — verifying the wire contract against the genuine gate, not a
    copy. Public checkouts leave TOKENIZER_SERVER_DIR unset and simply skip those
    two cross-checks; the full client behaviour below is still verified;
  • planted conversation content NEVER appears in what would be sent;
  • the opt-in gates hold: no creds -> no upload; creds but bridge not connected
    -> no upload; config off-switch -> no upload;
  • once-per-day marker dedupes; a failed POST writes NO marker (honest retry);
  • a dirty summary is refused before any send (MOAT tripwire).

Run: python3 test_usage_upload.py    (exit 0 = all pass)
"""
import json
import os
import sys
import tempfile
import types
from pathlib import Path

CLIENT_READER = Path(__file__).resolve().parents[2] / "reader"
# Optional server cross-check: supplied out-of-band on dev machines via the
# TOKENIZER_SERVER_DIR env var (a server checkout). NEVER hardcoded — public
# checkouts leave it unset and skip the two server-side assertions.
_SRV_ENV = os.environ.get("TOKENIZER_SERVER_DIR", "").strip()
SERVER_DIR = Path(_SRV_ENV) if _SRV_ENV else None
sys.path.insert(0, str(CLIENT_READER))

from cryptography.fernet import Fernet          # noqa: E402
import jsonl_reader                              # noqa: E402
import usage_uploader as up                      # noqa: E402

PASS = FAIL = 0


def check(name, cond, extra=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"PASS {name}")
    else:
        FAIL += 1
        print(f"FAIL {name}  {extra}")


# ── stub the server's web framework so we can import its REAL moat_violation ──
def _import_server_moat(store_dir: Path):
    fa = types.ModuleType("fastapi")

    class _App:
        def __init__(self, *a, **k):
            pass

        def _dec(self, *a, **k):
            return lambda fn: fn
        get = post = delete = put = patch = _dec

    class HTTPException(Exception):
        def __init__(self, status_code=400, detail=""):
            self.status_code, self.detail = status_code, detail

    def Header(default=None, *a, **k):
        return default

    fa.FastAPI, fa.Header, fa.HTTPException, fa.Request = _App, Header, HTTPException, object
    sys.modules["fastapi"] = fa
    far = types.ModuleType("fastapi.responses")
    far.JSONResponse = type("JSONResponse", (), {"__init__": lambda self, *a, **k: None})
    sys.modules["fastapi.responses"] = far
    pyd = types.ModuleType("pydantic")
    pyd.BaseModel = type("BaseModel", (), {})
    sys.modules["pydantic"] = pyd

    os.environ["TOKENIZER_STORE_DIR"] = str(store_dir)   # temp sqlite (import calls init_db)
    sys.path.insert(0, str(SERVER_DIR))
    import usage_server as srv                            # the genuine module
    return srv


def main():
    tmp = Path(tempfile.mkdtemp(prefix="e1upload_"))
    DATE = "2026-06-21"
    SECRET = "TOP_SECRET_PROMPT_TEXT_MUST_NEVER_LEAVE"

    # synthetic project log: real usage counters + PLANTED content we must not leak
    proj = tmp / "projects" / "proj1"
    proj.mkdir(parents=True)
    line = json.dumps({
        "timestamp": f"{DATE}T10:00:00Z", "sessionId": "sess-xyz", "requestId": "req-1",
        "message": {"id": "m1", "model": "claude-opus-4-8", "role": "assistant",
                    "content": SECRET,
                    "usage": {"input_tokens": 1000, "output_tokens": 200,
                              "cache_read_input_tokens": 50, "cache_creation_input_tokens": 10,
                              "server_tool_use": {"web_search_requests": 3}}}})
    (proj / "a.jsonl").write_text(line + "\n")
    jsonl_reader.PROJECTS = tmp / "projects"             # redirect the read-only scan

    srv = _import_server_moat(tmp / "store") if (SERVER_DIR and SERVER_DIR.exists()) else None

    # ── 1. summary shape + content absence ────────────────────────────────────
    summary = jsonl_reader.build_summary(DATE)
    blob = json.dumps(summary)
    pm0 = summary["per_model"][0]
    check("summary scanned the opus call", pm0["model"] == "claude-opus-4-8")
    check("input counter aggregated", pm0["in_tok"] == 1000 and pm0["out_tok"] == 200)
    check("cache counters aggregated", pm0["cache_r"] == 50 and pm0["cache_w"] == 10)
    check("NO conversation content in summary", SECRET not in blob)

    # ── 2. Fernet round-trip + REAL server MOAT on the client payload ─────────
    transit_key = Fernet.generate_key().decode()
    sealed = up.seal(summary, transit_key)
    decrypted = json.loads(Fernet(transit_key.encode()).decrypt(sealed.encode()))
    check("server decrypts client payload", decrypted.get("date") == DATE)
    check("payload has date + per_model (server-required)",
          isinstance(decrypted.get("date"), str) and isinstance(decrypted.get("per_model"), list))
    if srv is not None:
        viol = srv.moat_violation(decrypted)
        check("client payload passes REAL server moat_violation", viol is None, f"viol={viol}")
    else:
        print("SKIP server moat cross-check on decrypted payload (TOKENIZER_SERVER_DIR unset)")
    d_pm = decrypted["per_model"][0]
    check("per-model keys the server reads are present",
          all(k in d_pm for k in ("model", "in_tok", "out_tok", "cache_r", "cache_w")))
    check("decrypted payload carries NO content", SECRET not in json.dumps(decrypted))

    # ── 3. opt-in gates ──────────────────────────────────────────────────────
    creds_file = tmp / "creds.json"
    marker = tmp / ".last_upload"
    cfg = {"server_base": "https://example.invalid", "usage_path": "/tokenizer/v1/usage",
           "creds_path": str(creds_file), "upload_marker": str(marker),
           "upload_enabled": True, "upload_check_seconds": 1800}

    sent = {}

    def ok_poster(url, rid, tok, sealed_):
        sent.update(url=url, rid=rid, tok=tok, sealed=sealed_)
        return (True, 200, json.dumps({"stored": 1, "date": DATE}))

    # GATE 1: no creds at all
    r = up.upload_once(CLIENT_READER, connected=True, date=DATE, cfg=cfg, poster=ok_poster)
    check("GATE no-creds -> skip", r["reason"].startswith("no-creds") and not r["uploaded"])

    creds_file.write_text(json.dumps({"registry_id": "a" * 32,
                                      "install_token": "install-tok-xyz",
                                      "transit_key": transit_key}))

    # GATE 2: enrolled but bridge NOT connected
    r = up.upload_once(CLIENT_READER, connected=False, date=DATE, cfg=cfg, poster=ok_poster)
    check("GATE not-connected -> skip", "bridge-not-connected" in r["reason"] and not r["uploaded"])

    # GATE off-switch
    r = up.upload_once(CLIENT_READER, connected=True, date=DATE,
                       cfg=dict(cfg, upload_enabled=False), poster=ok_poster)
    check("GATE config off-switch -> skip", r["reason"] == "upload-disabled-in-config")

    # HAPPY PATH: connected + creds + fresh day
    r = up.upload_once(CLIENT_READER, connected=True, date=DATE, cfg=cfg, poster=ok_poster)
    check("HAPPY connected+creds -> uploaded", r["uploaded"] is True and r["status"] == 200)
    check("posted to configured usage_url",
          sent.get("url") == "https://example.invalid/tokenizer/v1/usage", sent.get("url"))
    check("Bearer carries install_token (not transit key, not bridge token)",
          sent.get("tok") == "install-tok-xyz")
    check("registry_id tags the envelope", sent.get("rid") == "a" * 32)
    posted = json.loads(Fernet(transit_key.encode()).decrypt(sent["sealed"].encode()))
    if srv is not None:
        check("POSTED payload passes server moat", srv.moat_violation(posted) is None)
    check("POSTED payload has NO content", SECRET not in json.dumps(posted))
    check("marker written on 200", marker.read_text().strip() == DATE)
    check("marker is 0600", (marker.stat().st_mode & 0o777) == 0o600)

    # DEDUPE: same day again
    r = up.upload_once(CLIENT_READER, connected=True, date=DATE, cfg=cfg, poster=ok_poster)
    check("DEDUPE already-today -> skip", r["reason"] == "already-uploaded-today")

    # HONEST FAILURE: 500 -> no marker, no fake success
    marker.unlink()

    def fail_poster(url, rid, tok, sealed_):
        return (False, 500, "internal error")
    r = up.upload_once(CLIENT_READER, connected=True, date=DATE, cfg=cfg, poster=fail_poster)
    check("FAIL 500 -> not uploaded", r["uploaded"] is False and r["reason"] == "http-500")
    check("FAIL 500 -> NO marker (retries next cycle)", not marker.exists())

    # NETWORK DOWN: status 0 -> no marker
    def down_poster(url, rid, tok, sealed_):
        return (False, 0, "connection refused")
    r = up.upload_once(CLIENT_READER, connected=True, date=DATE, cfg=cfg, poster=down_poster)
    check("FAIL network -> not uploaded, no marker", not r["uploaded"] and not marker.exists())

    # MOAT TRIPWIRE: a dirty summary must be refused before any send
    dirty = dict(summary)
    dirty["advice"] = [{"kind": "x", "content": "leaked user prompt"}]
    orig = up.build_summary
    up.build_summary = lambda d: dirty
    try:
        r = up.upload_once(CLIENT_READER, connected=True, date=DATE,
                           cfg=dict(cfg, upload_marker=str(tmp / ".m2")), poster=ok_poster)
    finally:
        up.build_summary = orig
    check("MOAT tripwire: dirty summary refused, nothing sent",
          r["reason"].startswith("moat-violation") and not r["uploaded"]
          and not (tmp / ".m2").exists())

    # reader's own moat negative-path selftest still green
    check("reader moat_check negative-path selftest", jsonl_reader.selftest() == 0)

    print(f"\n{PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
