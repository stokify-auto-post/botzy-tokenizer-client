#!/usr/bin/env python3
"""
usage_uploader.py — Phase E1: opt-in, bridge-gated DAILY upload of the reader's
per-model token-summary to the server endpoint POST /v1/usage.

This is the missing wire from AUDIT m7: enroll already mints a transit_key and the
server already exposes POST /v1/usage with a full Fernet round-trip, but the
shipping reader never uploaded. This module connects them — and ONLY them; it does
not invent a new payload shape or a new crypto scheme.

────────────────────────────────────────────────────────────────────────────────
WHAT LEAVES THE MACHINE (and nothing else):
  the moat-clean summary produced by jsonl_reader.build_summary() — model name,
  the four usage counters (in/out/cache_read/cache_creation), web-search COUNT
  (inside advice, as a number), the date, and derived aggregates. The registry_id
  rides in the (cleartext) envelope so the server can route the row. The SAME
  moat_check() that already gates the local summary is re-run here on the exact
  object about to be sealed — a dirty object is NEVER sent. We never send
  conversation content, prompts, responses, file bodies, keys, or the bridge token.

CONTRACT (the server's public POST /v1/usage wire contract — do not change here):
  body  = {"registry_id": "<32 lowercase hex>", "payload": "<fernet token>"}
  header= Authorization: Bearer <install_token>
  payload= Fernet(transit_key).encrypt(json(summary))   # transit_key from creds.json
  summary must carry date(str) + per_model(list) and pass the server's MOAT
  (top-level keys ⊆ ALLOWED_TOP, no forbidden keys) — build_summary() already does.
  server replaces that UTC date's rows atomically; 200 on success.

GATING (opt-in — three independent gates, all must hold):
  (1) creds.json present  -> the install ENROLLED with the server (registry_id +
      install_token + transit_key). A free widget / un-enrolled reader has none.
  (2) bridge CONNECTED    -> a widget has paired/polled this run (is_connected()).
      A free-standing reader nobody connected to never uploads.  ("no bridge =
      basic monitoring only" is preserved.)
  (3) today not yet sent  -> a 0600 marker holds the last uploaded UTC date;
      one upload per UTC day, replace-on-repeat is the server's job.

HONEST FAILURE (B3 lesson — no write-only queue, no fake "sent"):
  on ANY failure (deps missing, network, 4xx/5xx, decrypt) we log the REAL reason
  and DO NOT write the success marker, so the next cycle retries the same day. We
  never claim success when it wasn't, and never lose a day's numbers (the server
  replaces the date on the next good upload).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent           # the installed reader/ dir

# ── soft deps: the bridge must NEVER crash because upload deps are absent ──────
try:
    from cryptography.fernet import Fernet
    HAVE_CRYPTO = True
except Exception:                                # pragma: no cover - env dependent
    Fernet = None                                # type: ignore
    HAVE_CRYPTO = False

try:
    import yaml
except Exception:                                # pragma: no cover - env dependent
    yaml = None                                  # type: ignore

# build_summary + moat_check live beside this file (client reader/).
try:
    from jsonl_reader import build_summary, moat_check
except Exception:                                # pragma: no cover
    sys.path.insert(0, str(HERE))
    from jsonl_reader import build_summary, moat_check  # type: ignore


def log(msg: str) -> None:
    """One honest line to stdout (the reader's --logfile / journald). No secrets."""
    print(f"[{_now_iso()}] usage-upload: {msg}", flush=True)


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def utc_today() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def _expand(p: str) -> str:
    """Expand ${HOME} / $VARS / ~ — installer_config.yaml stores them literally."""
    return os.path.expanduser(os.path.expandvars(str(p)))


# ── config resolution (R13: URL + paths come from installer_config.yaml) ──────
def find_config(reader_dir: Path = HERE) -> Path | None:
    """Locate installer_config.yaml without hardcoding a single absolute path.

    Order: explicit env override -> install layout (setup.sh copies it next to
    reader/ at <install_root>/installer_config.yaml) -> dev checkout
    (<repo>/installer/installer_config.yaml). None if not found."""
    reader_dir = Path(reader_dir)
    env = os.environ.get("TOKENIZER_INSTALLER_CONFIG")
    candidates = []
    if env:
        candidates.append(Path(env))
    candidates += [
        reader_dir.parent / "installer_config.yaml",            # installed layout
        reader_dir.parent / "installer" / "installer_config.yaml",  # dev checkout
    ]
    for c in candidates:
        if c.is_file():
            return c
    return None


def load_config(reader_dir: Path = HERE) -> dict:
    path = find_config(reader_dir)
    if not path or yaml is None:
        return {}
    try:
        with open(path) as fh:
            return yaml.safe_load(fh) or {}
    except Exception as e:
        log(f"could not read installer_config.yaml ({path}): {e}")
        return {}


def usage_url(cfg: dict) -> str | None:
    base = (cfg.get("server_base") or "").rstrip("/")
    path = cfg.get("usage_path") or ""
    if not base or not path:
        return None
    if not path.startswith("/"):
        path = "/" + path
    return base + path


def advice_url(cfg: dict, registry_id: str) -> str | None:
    """E4 DELIVERY (pull side): the URL of THIS install's OWN registry-tagged static
    advice file. `advice_path` is a template carrying {registry_id} (R13). Returns
    None if unconfigured. The id is substituted verbatim (it is 32 hex from creds)."""
    base = (cfg.get("server_base") or "").rstrip("/")
    path = cfg.get("advice_path") or ""
    if not base or not path or not registry_id:
        return None
    if not path.startswith("/"):
        path = "/" + path
    return base + path.replace("{registry_id}", registry_id)


def creds_path(cfg: dict, reader_dir: Path = HERE) -> Path:
    cp = cfg.get("creds_path")
    if cp:
        return Path(_expand(cp))
    return reader_dir.parent / "creds.json"          # install layout fallback


def marker_path(cfg: dict, reader_dir: Path = HERE) -> Path:
    mp = cfg.get("upload_marker")
    if mp:
        return Path(_expand(mp))
    return creds_path(cfg, reader_dir).parent / ".last_upload"


def check_interval(cfg: dict) -> int:
    try:
        return max(60, int(cfg.get("upload_check_seconds") or 1800))
    except (TypeError, ValueError):
        return 1800


def upload_enabled(cfg: dict) -> bool:
    v = cfg.get("upload_enabled", True)              # default ON (still gated by creds+bridge)
    return str(v).strip().lower() not in ("0", "false", "no", "off")


# ── creds (registry_id + install_token + transit_key — the enroll response) ───
def load_creds(path: Path) -> dict | None:
    try:
        d = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(d, dict):
        return None
    for k in ("registry_id", "install_token", "transit_key"):
        if not isinstance(d.get(k), str) or not d[k]:
            return None
    return d


# ── per-day marker (0600) ─────────────────────────────────────────────────────
def read_marker(path: Path) -> str | None:
    try:
        return Path(path).read_text().strip() or None
    except OSError:
        return None


def write_marker(path: Path, date: str) -> None:
    p = Path(path)
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(str(p), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as fh:
            fh.write(date + "\n")
        os.chmod(str(p), 0o600)
    except OSError as e:
        log(f"WARNING: could not write upload marker {p}: {e} (may re-upload)")


# ── crypto + transport (reuse the EXISTING transit_key + Fernet path) ─────────
def seal(summary: dict, transit_key: str) -> str:
    """Fernet-seal with the per-install transit_key — exactly what the server
    decrypts. Compact JSON; no whitespace padding leaks structure."""
    token = Fernet(transit_key.encode())
    return token.encrypt(json.dumps(summary, separators=(",", ":")).encode()).decode()


def _post(url: str, registry_id: str, install_token: str, sealed: str,
          timeout: float = 20.0) -> tuple[bool, int, str]:
    """POST the envelope. Returns (ok, status, body). status 0 = no response
    (network/timeout). ok iff HTTP 200 (the server's success code for /v1/usage)."""
    body = json.dumps({"registry_id": registry_id, "payload": sealed}).encode()
    req = urllib.request.Request(
        url, data=body, method="POST",
        headers={"Content-Type": "application/json",
                 "Authorization": f"Bearer {install_token}"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return (resp.status == 200, resp.status, resp.read(2048).decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = e.read(2048).decode("utf-8", "replace")
        except Exception:
            pass
        return (False, e.code, detail)
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        return (False, 0, str(e))


# ── the gated, honest, one-shot upload ────────────────────────────────────────
def upload_once(reader_dir: Path = HERE, *, connected: bool, date: str | None = None,
                poster=_post, cfg: dict | None = None) -> dict:
    """Run the full gate -> build -> moat -> seal -> POST flow exactly once.

    Returns a structured result dict (also drives the offline tests). Never raises
    for an expected condition (missing creds, not connected, network error, http
    error) — it logs honestly and returns reason. `poster` is injectable so tests
    can exercise success/failure without touching the live server."""
    reader_dir = Path(reader_dir)
    res = {"uploaded": False, "skipped": True, "reason": None,
           "status": None, "date": date}

    if not HAVE_CRYPTO:
        log("skip: 'cryptography' not installed — cannot Fernet-seal "
            "(pip install --user cryptography). Bridge keeps running; upload disabled.")
        res["reason"] = "no-cryptography"
        return res

    cfg = load_config(reader_dir) if cfg is None else cfg
    if not upload_enabled(cfg):
        res["reason"] = "upload-disabled-in-config"
        return res

    creds = load_creds(creds_path(cfg, reader_dir))
    if not creds:                                    # GATE 1: enrolled?
        res["reason"] = "no-creds (not enrolled / free tier) — not uploading"
        return res

    if not connected:                                # GATE 2: bridge connected?
        res["reason"] = "bridge-not-connected (no widget paired this run) — not uploading"
        return res

    date = date or utc_today()
    res["date"] = date
    marker = marker_path(cfg, reader_dir)
    if read_marker(marker) == date:                  # GATE 3: already done today?
        res["reason"] = "already-uploaded-today"
        return res

    url = usage_url(cfg)
    if not url:
        log("skip: no usage URL (server_base + usage_path) in installer_config.yaml")
        res["reason"] = "no-usage-url"
        return res

    # build + MOAT (refuse to send a dirty object — belt AND suspenders) ───────
    try:
        summary = build_summary(date)
        moat_check(summary)
    except AssertionError as e:                       # MOAT tripwire
        log(f"ABORT — MOAT violation, NOTHING sent: {e}")
        res["reason"] = f"moat-violation: {e}"
        return res
    except Exception as e:
        log(f"skip: could not build summary for {date}: {e}")
        res["reason"] = f"build-error: {e}"
        return res

    try:
        sealed = seal(summary, creds["transit_key"])
    except Exception as e:
        log(f"skip: could not seal payload: {e}")
        res["reason"] = f"seal-error: {e}"
        return res

    ok, status, body = poster(url, creds["registry_id"], creds["install_token"], sealed)
    res["status"] = status
    res["skipped"] = False
    if ok:
        write_marker(marker, date)                   # mark sent ONLY on real 200
        log(f"OK — uploaded {date} summary "
            f"({len(summary.get('per_model', []))} models) to {url}")
        res["uploaded"] = True
        res["reason"] = "ok"
    else:
        # HONEST failure — no marker, retry next cycle, do NOT claim success.
        snippet = (body or "").replace("\n", " ")[:200]
        log(f"FAILED (status {status}) — will retry next cycle; nothing lost. "
            f"server: {snippet}")
        res["reason"] = f"http-{status}"
    return res


# ── E4 DELIVERY (pull side): read THIS install's OWN engine advice ────────────
# Mirrors the upload one-way principle in reverse: the server only WRITES a static,
# registry-ID-tagged file; the reader only READS its own (a read-only GET, no body,
# no endpoint logic). MOAT (defence in depth): even though the server already wrote
# OUTCOME-ONLY advice, we re-strip on receive to {kind, message, model?} and bound
# every string — a poisoned file can never smuggle content/derivation to the widget.
_ADVICE_FORBIDDEN = {"prompt", "response", "content", "messages", "body", "text",
                     "raw", "code", "file", "api_key", "apikey", "key", "secret",
                     "authorization", "bearer", "headers", "token", "registry_id",
                     "id", "ts", "uuid", "session_id", "cwd", "gitbranch"}
_SERVER_ADVICE_TTL = 300.0       # seconds; advice changes daily, poll cadence ~300s
_MAX_SERVER_ADVICE = 50
_server_advice_cache = {"date": None, "at": 0.0, "advice": []}


def _get(url: str, install_token: str, timeout: float = 15.0) -> tuple[bool, int, str]:
    """Read-only GET of the static advice file. Returns (ok, status, body). 404 (no
    file yet) and network/timeout (status 0) are NORMAL, not errors — the caller
    shows nothing extra. ok iff HTTP 200."""
    req = urllib.request.Request(
        url, method="GET",
        headers={"Accept": "application/json",
                 "Authorization": f"Bearer {install_token}"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return (resp.status == 200, resp.status, resp.read(65536).decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        return (False, e.code, "")
    except (urllib.error.URLError, TimeoutError, OSError):
        return (False, 0, "")


def _strip_server_advice(items) -> list:
    """MOAT on receive: copy ONLY the outcome fields, drop any item carrying a
    forbidden key, bound every string. We never echo a field we didn't ask for."""
    out = []
    if not isinstance(items, list):
        return out
    for a in items[:_MAX_SERVER_ADVICE]:
        if not isinstance(a, dict):
            continue
        if any(str(k).lower() in _ADVICE_FORBIDDEN for k in a):
            continue                                  # refuse the whole dirty item
        msg = a.get("message")
        if not isinstance(msg, str) or not msg.strip():
            continue
        item = {"kind": str(a.get("kind") or "engine")[:40], "message": msg[:300]}
        if isinstance(a.get("model"), str) and a["model"]:
            item["model"] = a["model"][:60]
        out.append(item)
    return out


def fetch_server_advice(reader_dir: Path = HERE, *, getter=_get, cfg=None) -> list:
    """Pull THIS install's OWN server/engine advice (outcome-only), moat-stripped.

    Gated on enrollment (creds.json present): a free / un-enrolled reader pulls
    nothing. Verifies the file is tagged with OUR registry_id (pull only our own ID).
    Returns [] on no-creds, no-config, 404, mismatch, or any error — never raises,
    never blocks the bridge. TTL-cached so a /v1/state poll never re-hits the wire.
    `getter` is injectable so the offline tests need no live server."""
    reader_dir = Path(reader_dir)
    cfg = load_config(reader_dir) if cfg is None else cfg

    creds = load_creds(creds_path(cfg, reader_dir))   # GATE: enrolled?
    if not creds:
        return []
    try:
        today = utc_today()
    except Exception:
        return []
    now = time.time()
    if _server_advice_cache["date"] == today and (now - _server_advice_cache["at"]) < _SERVER_ADVICE_TTL:
        return _server_advice_cache["advice"]

    advice: list = []
    rid = creds["registry_id"]
    url = advice_url(cfg, rid)
    if url:
        ok, status, body = getter(url, creds["install_token"])
        if ok and body:
            try:
                doc = json.loads(body)
                # pull ONLY our own: the file must be tagged with OUR registry_id
                if isinstance(doc, dict) and doc.get("registry_id") == rid:
                    advice = _strip_server_advice(doc.get("advice"))
            except (ValueError, TypeError):
                advice = []                            # malformed file -> show nothing extra
    _server_advice_cache.update({"date": today, "at": now, "advice": advice})
    return advice


# ── background loop (hooks into the persistent reader; not a new OS daemon) ────
def run_loop(reader_dir: Path, is_connected, stop=None) -> None:
    """Periodically re-evaluate the gate and upload at most once per UTC day.

    Started as a daemon thread by local_bridge.main(). `is_connected` is a 0-arg
    callable returning the bridge's current connected state. `stop` is an optional
    threading.Event for clean shutdown (mainly for tests)."""
    reader_dir = Path(reader_dir)
    cfg = load_config(reader_dir)
    interval = check_interval(cfg)
    if not upload_enabled(cfg):
        log("daily upload disabled in installer_config.yaml — loop not started.")
        return
    log(f"daily upload loop armed (interval {interval}s; gated on creds + bridge-connected).")
    while True:
        try:
            upload_once(reader_dir, connected=bool(is_connected()), cfg=load_config(reader_dir))
        except Exception as e:                        # never let the loop die
            log(f"loop error (continuing): {e}")
        if stop is not None:
            if stop.wait(interval):
                log("upload loop stopping.")
                return
        else:
            time.sleep(interval)


# ── manual / test CLI ─────────────────────────────────────────────────────────
def main() -> int:
    ap = argparse.ArgumentParser(description="manual daily usage upload (normally "
                                             "run by the reader's background loop)")
    ap.add_argument("--date", default=None, help="UTC date YYYY-MM-DD (default: today)")
    ap.add_argument("--assume-connected", action="store_true",
                    help="simulate a connected bridge (manual/testing only — the real "
                         "path requires an actual widget pairing)")
    ap.add_argument("--dry-run", action="store_true",
                    help="build + moat-check + seal, but DO NOT POST")
    args = ap.parse_args()

    if args.dry_run:
        def _noop(url, rid, tok, sealed):
            log(f"(dry-run) would POST {len(sealed)} bytes to {url} as {rid[:8]}…")
            return (False, -1, "dry-run: not sent")
        res = upload_once(connected=args.assume_connected, date=args.date, poster=_noop)
    else:
        res = upload_once(connected=args.assume_connected, date=args.date)
    print(json.dumps(res, indent=2))
    return 0 if (res["uploaded"] or args.dry_run) else 1


if __name__ == "__main__":
    sys.exit(main())
