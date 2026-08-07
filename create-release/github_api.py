#!/usr/bin/env python3
"""Requests against the GitHub REST API, using the standard library only.

The API root comes from GITHUB_API_URL. Responses are returned with their
status rather than raised; only the caller knows which statuses are errors.
"""

import json
import os
import urllib.error
import urllib.request
from typing import Any


def request(method: str, path: str, payload: dict | None = None) -> tuple[int, Any]:
    """The response status and decoded JSON body for an API call.

    Connection-level failures return status 0 with the reason under "message".
    """
    url = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/") + path
    body = None if payload is None else json.dumps(payload).encode()
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {os.environ['GH_TOKEN']}",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if body is not None:
        headers["Content-Type"] = "application/json"

    call = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(call, timeout=30) as response:
            return response.status, _decode(response.read())
    except urllib.error.HTTPError as error:
        return error.code, _decode(error.read())
    except urllib.error.URLError as error:
        return 0, {"message": str(error.reason)}


def error_message(body: Any) -> str:
    """The human-readable reason an API call failed."""
    if isinstance(body, dict):
        message = str(body.get("message", body))
        codes = ", ".join(
            str(error["code"])
            for error in body.get("errors", [])
            if isinstance(error, dict) and "code" in error
        )
        return f"{message} ({codes})" if codes else message
    return str(body)


def _decode(raw: bytes) -> Any:
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {"message": raw.decode(errors="replace")}
