#!/usr/bin/env python3
"""A tiny echo server for curlite's integration tests.

Every route answers with JSON describing what it received, so an assertion can
check that headers, bodies and methods survived the trip intact.

  GET  /json            a fixed JSON document
  ANY  /echo            method, path, query, headers and body, as JSON
  GET  /status/<code>   respond with that status
  GET  /redirect/<n>    n redirects, then /echo
  GET  /slow?ms=500     sleep, then reply
  GET  /text            text/plain
  GET  /xml             application/xml
  GET  /binary          application/octet-stream
  GET  /cookie/set      sets two cookies
  GET  /cookie/read     echoes the Cookie header back
  GET  /basic-auth      401 unless Authorization: Basic dXNlcjpwYXNz
  POST /graphql         echoes the parsed GraphQL payload
"""

import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # keep the test output clean
        pass

    def _send(self, code, body=b"", ctype="application/json", extra=None):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or []):
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def handle_one_request(self):
        try:
            super().handle_one_request()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _route(self):
        url = urlparse(self.path)
        path, query = url.path, parse_qs(url.query)

        if path == "/json":
            return self._send(200, json.dumps({
                "slideshow": {"title": "Sample Slide Show", "slides": [{"title": "Wake up"}]},
                "count": 2,
            }))

        if path == "/echo":
            raw = self._body()
            try:
                parsed = json.loads(raw)
            except Exception:
                parsed = None
            return self._send(200, json.dumps({
                "method": self.command,
                "path": path,
                "query": {k: v[0] if len(v) == 1 else v for k, v in query.items()},
                "headers": {k.lower(): v for k, v in self.headers.items()},
                "body": raw.decode("utf-8", "replace"),
                "json": parsed,
            }))

        if path.startswith("/status/"):
            code = int(path.rsplit("/", 1)[1])
            return self._send(code, json.dumps({"status": code}))

        if path.startswith("/redirect/"):
            n = int(path.rsplit("/", 1)[1])
            target = f"/redirect/{n - 1}" if n > 1 else "/echo"
            return self._send(302, b"", extra=[("Location", target)])

        if path == "/slow":
            time.sleep(int(query.get("ms", ["100"])[0]) / 1000)
            return self._send(200, json.dumps({"slept": True}))

        if path == "/text":
            return self._send(200, "hello world", ctype="text/plain")

        if path == "/xml":
            return self._send(
                200,
                "<?xml version='1.0'?><root><item id='1'>one</item><item id='2'>two</item></root>",
                ctype="application/xml",
            )

        if path == "/binary":
            return self._send(200, bytes([0, 1, 2, 3, 0, 255]), ctype="application/octet-stream")

        if path == "/cookie/set":
            return self._send(200, json.dumps({"ok": True}), extra=[
                ("Set-Cookie", "session=abc123; Path=/"),
                ("Set-Cookie", "flavour=choc; Path=/"),
            ])

        if path == "/cookie/read":
            return self._send(200, json.dumps({"cookie": self.headers.get("Cookie", "")}))

        if path == "/basic-auth":
            auth = self.headers.get("Authorization", "")
            if auth == "Basic dXNlcjpwYXNz":
                return self._send(200, json.dumps({"authenticated": True, "user": "user"}))
            return self._send(401, json.dumps({"authenticated": False}),
                              extra=[("WWW-Authenticate", 'Basic realm="curlite"')])

        if path == "/graphql":
            payload = json.loads(self._body() or b"{}")
            return self._send(200, json.dumps({"data": {"received": payload}}))

        return self._send(404, json.dumps({"error": "not found", "path": path}))

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = _route


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    # Print the real port so the test runner can find it on an ephemeral bind.
    print(server.server_address[1], flush=True)
    server.serve_forever()
