#!/usr/bin/env python3
"""Tests the REST transport in github_api.py against a real local server.

The other suites mock this module out, so this one is where an actual HTTP
exchange happens: the auth header reaching the wire, an error body coming back
decoded instead of raised, a connection failure reported like an API error.

Usage: python3 create-release/test_github_api.py
"""

import json
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import github_api


class RecordingServer(HTTPServer):
    """Serves one canned response and records what arrived."""

    canned: tuple[int, object]
    seen: list[dict]


class Handler(BaseHTTPRequestHandler):
    def _respond(self):
        assert isinstance(self.server, RecordingServer)
        length = int(self.headers.get("Content-Length", 0))
        self.server.seen.append(
            {
                "method": self.command,
                "path": self.path,
                "headers": dict(self.headers),
                "body": self.rfile.read(length).decode() if length else "",
            }
        )
        status, body = self.server.canned
        raw = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        self._respond()

    def do_POST(self):
        self._respond()

    def do_PATCH(self):
        self._respond()

    def log_message(self, format: str, *args: object) -> None:
        pass


class TestRequest(unittest.TestCase):
    def serve(self, status, body):
        server = RecordingServer(("127.0.0.1", 0), Handler)
        server.canned = (status, body)
        server.seen = []
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.shutdown)
        environment = {
            "GITHUB_API_URL": f"http://127.0.0.1:{server.server_port}",
            "GH_TOKEN": "test-token",
        }
        patcher = mock.patch.dict(github_api.os.environ, environment, clear=False)
        patcher.start()
        self.addCleanup(patcher.stop)
        return server

    def test_sends_the_token_and_api_headers(self):
        server = self.serve(200, [])
        github_api.request("GET", "/repos/owner/repo/tags?page=1")

        (seen,) = server.seen
        self.assertEqual(seen["method"], "GET")
        self.assertEqual(seen["path"], "/repos/owner/repo/tags?page=1")
        self.assertEqual(seen["headers"]["Authorization"], "Bearer test-token")
        self.assertEqual(seen["headers"]["Accept"], "application/vnd.github+json")

    def test_a_payload_travels_as_json(self):
        server = self.serve(201, {"id": 1})
        status, body = github_api.request(
            "POST", "/repos/owner/repo/releases", {"tag_name": "v1.0"}
        )

        (seen,) = server.seen
        self.assertEqual(json.loads(seen["body"]), {"tag_name": "v1.0"})
        self.assertEqual(seen["headers"]["Content-Type"], "application/json")
        self.assertEqual((status, body), (201, {"id": 1}))

    def test_an_error_status_returns_its_decoded_body(self):
        # Callers branch on 404 and 422, so an error response is an answer,
        # not an exception.
        self.serve(422, {"message": "Validation Failed"})
        status, body = github_api.request("POST", "/repos/owner/repo/releases", {})

        self.assertEqual(status, 422)
        self.assertEqual(body["message"], "Validation Failed")

    def test_a_connection_failure_reports_like_an_api_error(self):
        environment = {
            # A port from the ephemeral range with nothing listening on it.
            "GITHUB_API_URL": "http://127.0.0.1:9",
            "GH_TOKEN": "test-token",
        }
        with mock.patch.dict(github_api.os.environ, environment, clear=False):
            status, body = github_api.request("GET", "/anything")

        self.assertEqual(status, 0)
        self.assertTrue(body["message"])


class TestErrorMessage(unittest.TestCase):
    def test_includes_the_error_codes(self):
        body = {
            "message": "Validation Failed",
            "errors": [{"code": "already_exists"}],
        }
        self.assertEqual(
            github_api.error_message(body), "Validation Failed (already_exists)"
        )

    def test_survives_a_body_that_is_not_an_error_shape(self):
        self.assertEqual(github_api.error_message([1, 2]), "[1, 2]")


if __name__ == "__main__":
    unittest.main(verbosity=2)
