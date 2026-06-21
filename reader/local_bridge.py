#!/usr/bin/env python3
"""Botzy Tokenizer - Gate 1 localhost bridge. 127.0.0.1-ONLY, GET-only,
token+origin gated, numbers/state only. No request body ever read. Relays
already-numeric state only; discovered-knowledge LOGIC never touches this file."""
import argparse, hmac, json, os, secrets, socket, stat as _stat, sys, threading, time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
try:
    import yaml
except Exception:
    yaml = None
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CFG = os.path.join(HERE, "bridge_local_config.yaml")
def load_cfg(path=DEFAULT_CFG):
    cfg = {"bind_host":"127.0.0.1","port":8765,
           "token_file":os.path.join(HERE,".bridge_token"),
           "allowed_extension_origin":"chrome-extension://REPLACE_WITH_EXTENSION_ID",
           "state_path":"/v1/state","pair_path":"/v1/pair",
           "dtach_dir":"/tmp","dtach_prefix":"dtach-"}
    if yaml and os.path.exists(path):
        with open(path) as f: loaded = yaml.safe_load(f) or {}
        cfg.update({k:v for k,v in loaded.items() if v is not None})
    return cfg
def ensure_token(token_file):
    if os.path.exists(token_file):
        with open(token_file) as f: existing = f.read().strip()
        if existing:
            return existing
        # m10: the file exists but is empty/blank (truncated write, disk-full, manual
        # clear). The old code returned "" -> every request 401s forever with no
        # recovery. Treat an empty token like an absent one and RE-MINT it.
    tok = secrets.token_hex(32)
    fd = os.open(token_file, os.O_WRONLY|os.O_CREAT|os.O_TRUNC, 0o600)
    with os.fdopen(fd,"w") as f: f.write(tok)
    os.chmod(token_file, 0o600)
    print("\n"+"="*60+"\nBOTZY TOKENIZER BRIDGE TOKEN (paste into widget settings):\n  "+tok+"\n"+"="*60+"\n", flush=True)
    return tok
def collect_dtach_sessions(cfg):
    out=[]; d=cfg.get("dtach_dir","/tmp"); pre=cfg.get("dtach_prefix","dtach-")
    try:
        for name in os.listdir(d):
            if not name.startswith(pre): continue
            p=os.path.join(d,name)
            try:
                if not _stat.S_ISSOCK(os.stat(p).st_mode): continue
            except OSError: continue
            out.append({"name":name[len(pre):],"alive":True,"attached":_socket_has_peer(p)})
    except OSError: pass
    return out
def _socket_has_peer(path):
    s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
    try:
        s.settimeout(0.2); s.connect(path); return True
    except OSError: return False
    finally: s.close()
def count_project_logs():
    # COUNT (never content) of Claude Code *.jsonl logs under ~/.claude/projects.
    # Pure number -> lets the widget tell "bridge alive, no logs yet" apart from
    # "bridge offline". Never opens/reads a log line (MOAT: this file relays
    # numeric state only). Missing dir / unreadable -> 0.
    base = os.path.join(os.path.expanduser("~"), ".claude", "projects")
    n = 0
    try:
        for _root, _dirs, files in os.walk(base):
            for f in files:
                if f.endswith(".jsonl"): n += 1
    except OSError:
        pass
    return n
# ── E2: surface the reader's LOCAL advice to the widget (outcome-only) ─────────
# The reader already computes per-key advice (cache-savings, model-misuse,
# peak/web-search) in jsonl_reader.build_summary(). It was CLI-only. Here we relay
# JUST the advice[] MESSAGES across the bridge so the widget can show them.
#
# MOAT (absolute): we pass through the reader's already-phrased OUTCOME messages
# only — "₹X were cacheable", "opus is N% of the day's cost". We add NO new logic
# that reveals HOW advice is computed (the derivation/formula is server-side moat,
# never shipped). build_summary() already moat_checks itself; we re-run the SAME
# moat_check on the trimmed advice payload before it leaves this handler, and
# anything content-shaped (or oversized) is refused → relay nothing, never crash.
# Cached briefly so a /v1/state poll never re-walks every jsonl line.
_advice_cache = {"date": None, "at": 0.0, "advice": []}
_ADVICE_TTL = 300.0          # seconds; advice changes slowly, poll cadence is ~300s
_MAX_ADVICE = 50             # bound the list (well under jsonl_reader MAX_LIST=100)


def _utc_today():
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def build_advice(cfg=None):
    """Today's reader-computed advice MESSAGES (outcome-only), moat-clean.

    Pulls advice[] straight from jsonl_reader.build_summary (which already
    moat-checks itself), keeps ONLY the outcome fields ({kind, message, model?,
    inr?}), and re-runs the reader's moat_check on that trimmed payload. Returns
    [] on ANY problem (deps absent, build error, MOAT trip) — advice is
    best-effort and must NEVER break the bridge or the basic state."""
    try:
        from jsonl_reader import build_summary, moat_check
    except Exception:
        return []
    try:
        today = _utc_today()
    except Exception:
        return []
    now = time.time()
    if _advice_cache["date"] == today and (now - _advice_cache["at"]) < _ADVICE_TTL:
        return _advice_cache["advice"]
    out = []
    try:
        summary = build_summary(today)               # already moat-checked inside
        raw = (summary.get("advice") or [])[:_MAX_ADVICE]
        # BELT: re-run the reader's moat_check on the RAW advice. If anything
        # upstream is content-shaped, refuse the WHOLE payload (relay []) — never
        # selectively launder a dirty item by stripping it.
        moat_check(raw, path="$.advice")
        for a in raw:                                # SUSPENDERS: outcome fields only
            if not isinstance(a, dict):
                continue
            msg = str(a.get("message") or "")
            if not msg:
                continue
            item = {"kind": str(a.get("kind") or "tip"), "message": msg}
            if isinstance(a.get("model"), str) and a["model"]:
                item["model"] = a["model"]
            if isinstance(a.get("inr"), (int, float)) and not isinstance(a.get("inr"), bool):
                item["inr"] = a["inr"]
            out.append(item)
        moat_check(out, path="$.advice")             # re-check the trimmed payload too
    except Exception:
        out = []                                     # MOAT trip / build error → relay nothing
    _advice_cache.update({"date": today, "at": now, "advice": out})
    return out


def build_server_advice(cfg=None):
    """E4 DELIVERY: THIS install's OWN engine advice, pulled (read-only GET) from the
    server's registry-tagged static file by usage_uploader.fetch_server_advice and
    moat-stripped on receive. Enrollment-gated (no creds → []). Independent of local
    logs — the engine layer can have advice even before any Claude Code log exists.
    Best-effort: any import/runtime/MOAT problem → [] (never breaks the bridge)."""
    try:
        import usage_uploader
        return usage_uploader.fetch_server_advice(os.path.dirname(os.path.abspath(__file__)))
    except Exception:
        return []


def build_state(cfg):
    logs = count_project_logs()
    # LOCAL advice only when there ARE logs (preserves the B3 "connected, no logs yet"
    # empty-state). The /v1/state auth gate already ensures advice crosses ONLY on
    # a connected, authenticated poll — never to an unpaired widget.
    advice = build_advice(cfg) if logs > 0 else []
    # SERVER/ENGINE advice (E4): enrollment-gated, NOT log-gated — a separate layer
    # the widget labels distinctly from the local one. [] when un-enrolled / no file.
    server_advice = build_server_advice(cfg)
    return {"schema":"botzy.bridge.state.v1",
            "usage":{"five_hour_pct":None,"seven_day_pct":None,"resets_at":None},
            "logs_found":logs, "has_data":logs > 0,
            "advice": advice,
            "server_advice": server_advice,
            "dtach":collect_dtach_sessions(cfg)}
class Handler(BaseHTTPRequestHandler):
    cfg=None; token=None
    paired=False                 # one-time pairing window; closes after first success
    connected=False              # E1: flips True once a widget pairs OR authenticates a
                                 # /v1/state poll this run. Gates the daily usage upload —
                                 # a free-standing reader nobody connected to never uploads.
    _pair_lock=threading.Lock()  # ThreadingHTTPServer: serialise the close
    def _deny(self,code):
        self.send_response(code); self.send_header("Content-Type","application/json")
        self.send_header("Content-Length","2"); self.end_headers(); self.wfile.write(b"{}")
    def _ok(self,payload):
        body=json.dumps(payload).encode(); self.send_response(200)
        self.send_header("Content-Type","application/json")
        self.send_header("Access-Control-Allow-Origin", self.cfg["allowed_extension_origin"])
        self.send_header("Content-Length",str(len(body))); self.end_headers(); self.wfile.write(body)
    def _pair(self):
        # AUTO-PAIR: one-time, loopback-only delivery of the bridge token so the
        # widget never needs a manual paste. Two gates beyond the 127.0.0.1 bind:
        #  (1) require the custom header X-Botzy-Pair. A web page CANNOT send a
        #      custom header to a cross-origin loopback without a CORS preflight,
        #      which we never approve (no Access-Control-Allow-Headers / OPTIONS
        #      -> 501) — so only the extension service-worker (host_permission =
        #      no preflight) can deliver it. A page's plain "simple" GET (no
        #      header) is rejected WITHOUT consuming the window.
        #  (2) one-time: after the first success `paired` flips True and every
        #      later /v1/pair returns 403 — a later local process can't harvest
        #      the token here (it could already read the 0600 token file; this
        #      adds no new exposure, but closes the convenience hole).
        if not self.headers.get("X-Botzy-Pair"): return self._deny(403)
        with Handler._pair_lock:
            if Handler.paired: return self._deny(403)   # window already closed
            Handler.paired=True                          # close BEFORE delivering (fail-closed)
        Handler.connected=True                           # E1: a widget paired -> opt-in established
        body=json.dumps({"token":self.token}).encode(); self.send_response(200)
        self.send_header("Content-Type","application/json")
        self.send_header("Access-Control-Allow-Origin", self.cfg["allowed_extension_origin"])
        self.send_header("Content-Length",str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_POST(self): self._deny(405)
    do_PUT=do_POST; do_DELETE=do_POST; do_PATCH=do_POST
    def do_GET(self):
        # Unauthenticated liveness probe — no data, just {"ok":true}. Lets the
        # installer confirm the reader started without needing the bridge token.
        if self.path == "/health":
            body=b'{"ok":true}'; self.send_response(200)
            self.send_header("Content-Type","application/json")
            self.send_header("Content-Length",str(len(body))); self.end_headers()
            self.wfile.write(body); return
        if self.path == self.cfg.get("pair_path","/v1/pair"): return self._pair()
        if self.path != self.cfg["state_path"]: return self._deny(404)
        auth=self.headers.get("Authorization",""); presented=auth[7:] if auth.startswith("Bearer ") else ""
        if not (presented and hmac.compare_digest(presented, self.token)): return self._deny(401)
        # Origin gate removed: MV3 service-worker loopback fetch sends NO Origin
        # (browser strips it; JS cannot set it). Security = 127.0.0.1 bind + 64-char
        # constant-time token. CORS header still pins the extension id for the reply.
        Handler.connected=True                           # E1: authenticated widget poll -> connected
        return self._ok(build_state(self.cfg))
    def log_message(self,*a): pass
def make_server(cfg,token):
    Handler.cfg=cfg; Handler.token=token; host=cfg["bind_host"]
    if host not in ("127.0.0.1","::1","localhost"):
        raise SystemExit("REFUSING: bind_host must be loopback, got %r" % host)
    return ThreadingHTTPServer((host,int(cfg["port"])), Handler)
def main():
    # --config: full absolute path so a logon-launched reader (arbitrary cwd)
    # always finds its config. --logfile: when launched hidden (pythonw, no
    # console) the startup banner + first-run pairing token would vanish; redirect
    # them to this file so the installer smoke-test and the user can still see
    # "bridge listening" and the token. Both optional → manual `python
    # local_bridge.py` is unchanged (prints to stdout as before).
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=DEFAULT_CFG)
    ap.add_argument("--logfile", default=None)
    args = ap.parse_args()
    if args.logfile:
        lf = open(args.logfile, "a", buffering=1, encoding="utf-8")  # line-buffered, append
        sys.stdout = lf; sys.stderr = lf
    cfg=load_cfg(args.config); token=ensure_token(cfg["token_file"]); httpd=make_server(cfg,token)
    print("bridge listening on %s:%s%s"%(cfg["bind_host"],cfg["port"],cfg["state_path"]),flush=True)
    # E1: opt-in daily usage upload. Runs IN THIS persistent reader process (a daemon
    # thread, not a new OS service). Fully gated inside usage_uploader.upload_once —
    # uploads only when creds.json exists AND a widget has connected this run. Any
    # import/runtime error here must never stop the bridge from serving.
    try:
        import usage_uploader
        threading.Thread(
            target=usage_uploader.run_loop,
            args=(os.path.dirname(os.path.abspath(__file__)),),
            kwargs={"is_connected": lambda: Handler.connected},
            daemon=True,
        ).start()
    except Exception as e:
        print("usage upload loop not started (bridge unaffected): %r" % e, flush=True)
    try: httpd.serve_forever()
    except KeyboardInterrupt: httpd.shutdown()
if __name__=="__main__": main()
