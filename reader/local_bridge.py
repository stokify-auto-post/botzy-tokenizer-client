#!/usr/bin/env python3
"""Botzy Tokenizer - Gate 1 localhost bridge. 127.0.0.1-ONLY, GET-only,
token+origin gated, numbers/state only. No request body ever read. Relays
already-numeric state only; discovered-knowledge LOGIC never touches this file."""
import argparse, hmac, json, os, secrets, socket, stat as _stat, sys
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
           "state_path":"/v1/state","dtach_dir":"/tmp","dtach_prefix":"dtach-"}
    if yaml and os.path.exists(path):
        with open(path) as f: loaded = yaml.safe_load(f) or {}
        cfg.update({k:v for k,v in loaded.items() if v is not None})
    return cfg
def ensure_token(token_file):
    if os.path.exists(token_file):
        with open(token_file) as f: return f.read().strip()
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
def build_state(cfg):
    return {"schema":"botzy.bridge.state.v1",
            "usage":{"five_hour_pct":None,"seven_day_pct":None,"resets_at":None},
            "dtach":collect_dtach_sessions(cfg)}
class Handler(BaseHTTPRequestHandler):
    cfg=None; token=None
    def _deny(self,code):
        self.send_response(code); self.send_header("Content-Type","application/json")
        self.send_header("Content-Length","2"); self.end_headers(); self.wfile.write(b"{}")
    def _ok(self,payload):
        body=json.dumps(payload).encode(); self.send_response(200)
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
        if self.path != self.cfg["state_path"]: return self._deny(404)
        auth=self.headers.get("Authorization",""); presented=auth[7:] if auth.startswith("Bearer ") else ""
        if not (presented and hmac.compare_digest(presented, self.token)): return self._deny(401)
        # Origin gate removed: MV3 service-worker loopback fetch sends NO Origin
        # (browser strips it; JS cannot set it). Security = 127.0.0.1 bind + 64-char
        # constant-time token. CORS header still pins the extension id for the reply.
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
    try: httpd.serve_forever()
    except KeyboardInterrupt: httpd.shutdown()
if __name__=="__main__": main()
