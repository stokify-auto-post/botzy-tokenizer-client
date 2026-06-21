#!/usr/bin/env python3
"""
test_e4_delivery.py — OFFLINE proof for Phase E4 DELIVERY (pull side, client).

NO live server, NO nginx, NO network. The server's static advice file is simulated
with an INJECTED getter, proving locally:

  • the reader pulls ONLY its OWN registry-ID-tagged file (a wrong-id file is ignored);
  • a missing file (404) / network error -> [] gracefully, no crash, no error state;
  • MOAT on receive: a poisoned file (forbidden 'content' key, oversized strings) is
    stripped — content never reaches the widget; messages are bounded;
  • the GATE holds: an un-enrolled reader (no creds.json) pulls nothing;
  • build_state() carries a separate `server_advice` layer next to local `advice`,
    and the local-advice / has_data / B3 empty-state are all preserved.

Run: python3 test_e4_delivery.py     (exit 0 = all pass)
"""
import json
import sys
import tempfile
from pathlib import Path

CLIENT_READER = Path("/opt/tokenizer-client/reader")
sys.path.insert(0, str(CLIENT_READER))

import usage_uploader as up                       # noqa: E402
import local_bridge as lb                         # noqa: E402

PASS = FAIL = 0
RID = "0123456789abcdef0123456789abcdef"
DATE = "2026-06-21"


def check(name, cond, extra=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"PASS {name}")
    else:
        FAIL += 1
        print(f"FAIL {name}  {extra}")


def _cfg(creds_file):
    return {"server_base": "https://example.invalid",
            "advice_path": "/tokenizer/v1/advice/{registry_id}.json",
            "creds_path": str(creds_file)}


def _reset_cache():
    up._server_advice_cache.update({"date": None, "at": 0.0, "advice": []})


def _good_doc(rid=RID, advice=None):
    return json.dumps({
        "schema": "botzy.advice.v1", "registry_id": rid, "generated_at": "x",
        "advice": advice if advice is not None else [
            {"kind": "model_misuse_opus", "model": "opus", "severity": "high",
             "message": "Opus is doing bulk/parse-shaped work — a cheaper model fits."},
        ]})


def main():
    up.utc_today = lambda: DATE                    # pin the cache key
    tmp = Path(tempfile.mkdtemp(prefix="e4pull_"))
    creds_file = tmp / "creds.json"
    cfg = _cfg(creds_file)

    # ── GATE: no creds -> nothing pulled ─────────────────────────────────────
    _reset_cache()
    out = up.fetch_server_advice(CLIENT_READER, getter=lambda u, t: (True, 200, _good_doc()), cfg=cfg)
    check("GATE un-enrolled (no creds) -> [] (free tier pulls nothing)", out == [], f"out={out}")

    creds_file.write_text(json.dumps({"registry_id": RID, "install_token": "tok-xyz",
                                      "transit_key": "k"}))

    # ── HAPPY: own file pulled, outcome message present ──────────────────────
    seen = {}

    def good_getter(url, token):
        seen.update(url=url, token=token)
        return (True, 200, _good_doc())
    _reset_cache()
    out = up.fetch_server_advice(CLIENT_READER, getter=good_getter, cfg=cfg)
    check("HAPPY: own registry-tagged advice pulled", len(out) == 1 and "Opus" in out[0]["message"], f"out={out}")
    check("pulled from the registry-templated URL",
          seen.get("url") == f"https://example.invalid/tokenizer/v1/advice/{RID}.json", seen.get("url"))
    check("Bearer carries the install token", seen.get("token") == "tok-xyz")
    check("pulled item is outcome-only (kind/message/model only)",
          set(out[0]) <= {"kind", "message", "model"}, str(out[0]))

    # ── MISSING FILE: 404 -> [] graceful (no error, local advice still works) ─
    _reset_cache()
    out = up.fetch_server_advice(CLIENT_READER, getter=lambda u, t: (False, 404, ""), cfg=cfg)
    check("MISSING file (404) -> [] graceful", out == [], f"out={out}")
    _reset_cache()
    out = up.fetch_server_advice(CLIENT_READER, getter=lambda u, t: (False, 0, ""), cfg=cfg)
    check("NETWORK down (status 0) -> [] graceful", out == [])

    # ── ONLY OWN ID: a file tagged with someone else's id is ignored ─────────
    _reset_cache()
    other = _good_doc(rid="ffffffffffffffffffffffffffffffff")
    out = up.fetch_server_advice(CLIENT_READER, getter=lambda u, t: (True, 200, other), cfg=cfg)
    check("WRONG registry_id file -> ignored (pull only OUR own id)", out == [], f"out={out}")

    # ── MOAT on receive: poisoned file never leaks content ───────────────────
    secret = "TOP_SECRET_PROMPT_MUST_NEVER_REACH_THE_WIDGET"
    poisoned = json.dumps({
        "schema": "botzy.advice.v1", "registry_id": RID, "generated_at": "x",
        "advice": [
            {"kind": "ok", "message": "clean engine tip", "model": "opus"},   # kept
            {"kind": "leak", "message": "x", "content": secret},               # forbidden key -> dropped
            {"kind": "leak2", "message": "y", "prompt": secret},               # forbidden key -> dropped
            {"kind": "big", "message": "Z" * 5000},                            # bounded to 300
        ]})
    _reset_cache()
    out = up.fetch_server_advice(CLIENT_READER, getter=lambda u, t: (True, 200, poisoned), cfg=cfg)
    blob = json.dumps(out)
    check("MOAT: poisoned secret never reaches the widget", secret not in blob, blob[:160])
    check("MOAT: content-bearing items dropped, clean one kept",
          [a["message"] for a in out if a["message"] == "clean engine tip"] == ["clean engine tip"], f"out={out}")
    check("MOAT: oversized message bounded to <=300 chars",
          all(len(a["message"]) <= 300 for a in out))
    check("MOAT: no forbidden key survives on any pulled item",
          all(set(a) <= {"kind", "message", "model"} for a in out))

    # ── build_state(): server_advice is a SEPARATE layer; local layer intact ──
    # stub the reader's local-advice + has_data so we exercise BOTH layers offline.
    lb._utc_today = lambda: DATE
    lb.count_project_logs = lambda: 5              # "logs present" -> local advice path runs
    lb._advice_cache.update({"date": None, "at": 0.0, "advice": []})
    lb.build_advice = lambda cfg=None: [{"kind": "local", "message": "local-log advice line"}]
    _reset_cache()
    # point the reader's real fetch at our injected getter via cfg + a patched _get
    orig_fetch = up.fetch_server_advice
    up.fetch_server_advice = lambda reader_dir=CLIENT_READER, **k: [
        {"kind": "model_misuse_opus", "message": "engine: reserve Opus for reasoning", "model": "opus"}]
    try:
        state = lb.build_state({})
    finally:
        up.fetch_server_advice = orig_fetch
    check("/v1/state carries a SEPARATE server_advice layer",
          isinstance(state.get("server_advice"), list) and len(state["server_advice"]) == 1
          and "engine" in state["server_advice"][0]["message"], state.get("server_advice"))
    check("local advice layer still present alongside it",
          isinstance(state.get("advice"), list) and state["advice"] and state["advice"][0]["kind"] == "local")
    check("B3 fields intact (logs_found/has_data/dtach)",
          isinstance(state.get("logs_found"), int) and state.get("has_data") is True
          and isinstance(state.get("dtach"), list))
    blob2 = json.dumps(state)
    check("server_advice payload carries NO forbidden/content shape",
          all(set(a) <= {"kind", "message", "model"} for a in state["server_advice"]), blob2[:160])

    print(f"\n{PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
