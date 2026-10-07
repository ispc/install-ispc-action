#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Test real curl timeouts and retries against a stalled loopback HTTP server."""

import http.server
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest


PAYLOAD = b"x complete archive\n"
SCRIPT = Path(__file__).resolve().parents[1] / "install.sh"
BASH = r'''
source "$1"
backoff_sleep() { :; }
# Shorten configured timeouts for the test. Missing timeout flags remain
# missing, so the wrapper cannot hide an unbounded-transfer regression.
curl() {
  local args=()
  while (($#)); do
    case "$1" in
      --connect-timeout | --speed-time) args+=("$1" 1); shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  command curl "${args[@]}"
}
download "$2" "$3"
'''


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        attempts = self.server.attempts
        attempts[self.path] = attempts.get(self.path, 0) + 1
        if self.path == "/persistent" or attempts[self.path] == 1:
            if self.path == "/partial":
                self.send_response(200)
                self.send_header("Content-Length", str(len(PAYLOAD)))
                self.end_headers()
                self.wfile.write(PAYLOAD[:1])
                self.wfile.flush()
            self.server.stop.wait(5)
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(PAYLOAD)))
        self.end_headers()
        self.wfile.write(PAYLOAD)


class DownloadTimeoutTest(unittest.TestCase):
    def setUp(self):
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.attempts = {}
        self.server.stop = threading.Event()
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.stop.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def download(self, path):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "archive"
            url = f"http://127.0.0.1:{self.server.server_port}{path}"
            result = subprocess.run(
                ["bash", "-c", BASH, "--", str(SCRIPT), url, str(out)],
                capture_output=True, text=True, timeout=20,
                # Bypass any runner proxy for the loopback fixture.
                env={**os.environ, "no_proxy": "127.0.0.1"},
            )
            self.assertIn("curl exited with code 28", result.stdout)
            return result, out.read_bytes() if out.exists() else None

    def test_stalled_headers_are_retried(self):
        result, content = self.download("/headers")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.server.attempts["/headers"], 2)
        self.assertEqual(content, PAYLOAD)

    def test_stalled_body_is_discarded_before_retry(self):
        result, content = self.download("/partial")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.server.attempts["/partial"], 2)
        self.assertEqual(content, PAYLOAD)

    def test_persistent_stall_stops_after_three_attempts(self):
        result, content = self.download("/persistent")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.server.attempts["/persistent"], 3)
        self.assertIn("::error::Download failed: curl exited with code 28", result.stdout)
        self.assertIsNone(content)


if __name__ == "__main__":
    unittest.main()
