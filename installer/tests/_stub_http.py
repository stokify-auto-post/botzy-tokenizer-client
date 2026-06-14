#!/usr/bin/env python3
"""Tiny offline HTTP stub for installer tests. Returns a fixed status code for
ANY method/path. Usage: python3 _stub_http.py <port> <status>
Prints 'STUB_READY <port>' once bound so the caller can proceed."""
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]); STATUS = int(sys.argv[2])

class H(BaseHTTPRequestHandler):
    def _send(self):
        body = b'{"stub":true}'
        self.send_response(STATUS)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):  self._send()
    def do_POST(self): self._send()
    def log_message(self, *a): pass

srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
print("STUB_READY %d" % PORT, flush=True)
srv.serve_forever()
