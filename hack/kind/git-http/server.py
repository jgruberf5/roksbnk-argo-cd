#!/usr/bin/env python3
"""Minimal smart-HTTP git server: forwards every request to `git http-backend`
(CGI) over the repositories under GIT_PROJECT_ROOT. Read-only (no receive-pack)."""
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.environ.get("GIT_PROJECT_ROOT", "/repo")
PORT = int(os.environ.get("PORT", "8080"))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _cgi(self):
        path, _, query = self.path.partition("?")
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        env = dict(
            os.environ,
            GIT_PROJECT_ROOT=ROOT,
            GIT_HTTP_EXPORT_ALL="1",
            GATEWAY_INTERFACE="CGI/1.1",
            SERVER_PROTOCOL=self.protocol_version,
            REQUEST_METHOD=self.command,
            PATH_INFO=path,
            QUERY_STRING=query,
            CONTENT_TYPE=self.headers.get("Content-Type", ""),
            CONTENT_LENGTH=str(length),
            REMOTE_ADDR=self.client_address[0],
        )
        if self.headers.get("Content-Encoding"):
            env["HTTP_CONTENT_ENCODING"] = self.headers["Content-Encoding"]
        proc = subprocess.run(["git", "http-backend"], input=body, env=env, capture_output=True)
        head, _, payload = proc.stdout.partition(b"\r\n\r\n")
        status, headers = 200, []
        for line in head.decode(errors="replace").split("\r\n"):
            key, _, value = line.partition(":")
            if key.lower() == "status":
                status = int(value.strip().split()[0])
            elif key:
                headers.append((key, value.strip()))
        self.send_response(status)
        for key, value in headers:
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        if proc.stderr:
            sys.stderr.write(proc.stderr.decode(errors="replace"))

    do_GET = _cgi
    do_POST = _cgi

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s %s\n" % (self.client_address[0], self.command, self.path))


if __name__ == "__main__":
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()
