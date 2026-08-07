#!/usr/bin/env python3
"""Local fixture server for Pane's scenarios.

One file, stdlib only, Python 3.9 syntax — /usr/bin/python3 on a stock macOS.
Nothing here reaches the network, which is the point: a suite that depends on
the internet fails for reasons that have nothing to do with the code.

  ./fixture_server.py --port 8731              plain HTTP
  ./fixture_server.py --port 8732 --tls        HTTPS with a self-signed cert

Routes:
  /                     index
  /slow?ms=N            responds after N ms — for timeout paths
  /auth                 401 Basic, then 200 with the right credentials
  /download/<name>      Content-Disposition: attachment
  /big?mb=N             N MB attachment, for resume and progress
  /redirect?to=U        302
  /form                 a login form, for the credential vault (milestone F)
  /audio                a page that plays audio, for the never-discard rule
  /crash                a page that tries hard to kill its renderer
  /deep?n=N             pushes N history entries, for interactionState
  /notfound             404
"""
import argparse
import base64
import json
import os
import ssl
import subprocess
import sys
import tempfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

CREDS = base64.b64encode(b"pane:secret").decode()


class Handler(BaseHTTPRequestHandler):
    # Every request is logged so the gate can assert what was actually served —
    # "the page loaded" is worth nothing if the server never saw the request.
    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def _send(self, code, body=b"", ctype="text/html; charset=utf-8", extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        path = u.path

        if path == "/":
            self._send(200, b"<!doctype html><title>Pane fixtures</title><h1>Pane fixtures</h1>")

        elif path == "/slow":
            time.sleep(int(q.get("ms", ["1000"])[0]) / 1000.0)
            self._send(200, b"<!doctype html><title>Slow</title>slow response")

        elif path == "/auth":
            header = self.headers.get("Authorization", "")
            if header == "Basic " + CREDS:
                self._send(200, b"<!doctype html><title>Authenticated</title>AUTH-OK")
            else:
                self._send(401, b"unauthorized",
                           extra={"WWW-Authenticate": 'Basic realm="Pane Fixture"'})

        elif path.startswith("/download/"):
            name = os.path.basename(path) or "file.bin"
            body = b"PANE-DOWNLOAD-FIXTURE\n" * 200
            self._send(200, body, "application/octet-stream",
                       {"Content-Disposition": 'attachment; filename="%s"' % name})

        elif path == "/big":
            mb = int(q.get("mb", ["4"])[0])
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(mb * 1024 * 1024))
            self.send_header("Content-Disposition", 'attachment; filename="big.bin"')
            # Advertise ranges so resume can be exercised.
            self.send_header("Accept-Ranges", "bytes")
            self.end_headers()
            chunk = b"x" * 65536
            for _ in range(mb * 16):
                self.wfile.write(chunk)

        elif path == "/redirect":
            self._send(302, b"", extra={"Location": q.get("to", ["/"])[0]})

        elif path == "/form":
            self._send(200, b"""<!doctype html><title>Sign in</title>
<form method="post" action="/form">
  <input name="username" type="text" autocomplete="username">
  <input name="password" type="password" autocomplete="current-password">
  <button type="submit">Sign in</button>
</form>""")

        elif path == "/audio":
            # A silent oscillator: enough for WebKit to report media playback
            # without making noise during an unattended run.
            self._send(200, b"""<!doctype html><title>Audio</title>
<script>
  const ctx = new (window.AudioContext || window.webkitAudioContext)();
  const osc = ctx.createOscillator(), gain = ctx.createGain();
  gain.gain.value = 0.0001;
  osc.connect(gain); gain.connect(ctx.destination); osc.start();
  window.__panePlaying = true;
</script>""")

        elif path == "/crash":
            self._send(200, b"""<!doctype html><title>Crash</title>
<script>
  // Exhaust the renderer. Not guaranteed to kill it, so the scenario must
  // tolerate survival rather than assert the crash happened.
  const hog = [];
  try { for (;;) hog.push(new Uint8Array(1 << 24)); } catch (e) {}
</script>""")

        elif path == "/deep":
            n = int(q.get("n", ["12"])[0])
            self._send(200, ("""<!doctype html><title>Deep</title>
<script>
  for (let i = 0; i < %d; i++) history.pushState({i}, '', '/deep/step' + i);
  window.scrollTo(0, 800);
</script>
<div style="height:4000px">deep history</div>""" % n).encode())

        elif path == "/notfound":
            self._send(404, b"not found")

        else:
            self._send(404, b"no such fixture")

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8", "replace")
        self._send(200, ("<!doctype html><title>Posted</title>POSTED " + body).encode())


def self_signed(directory):
    """openssl is present on every macOS; no dependency needed."""
    key = os.path.join(directory, "key.pem")
    cert = os.path.join(directory, "cert.pem")
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
         "-keyout", key, "-out", cert, "-days", "1",
         "-subj", "/CN=pane-fixture.invalid"],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return cert, key


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8731)
    ap.add_argument("--tls", action="store_true")
    args = ap.parse_args()

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    if args.tls:
        # Deliberately self-signed and for a name that does not match, so the
        # cert interstitial has something real to fail on. The scenario must
        # EXPECT the failure, never trust it away.
        tmp = tempfile.mkdtemp()
        cert, key = self_signed(tmp)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(cert, key)
        server.socket = ctx.wrap_socket(server.socket, server_side=True)

    scheme = "https" if args.tls else "http"
    print(json.dumps({"rec": "fixtures", "url": "%s://127.0.0.1:%d" % (scheme, args.port)}))
    sys.stdout.flush()
    server.serve_forever()


if __name__ == "__main__":
    main()
