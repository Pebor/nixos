#!/usr/bin/env python3
"""hermes-status — one JSON endpoint answering "what is Hermes doing right now".

Sources, all local to the t490s:
  * http://127.0.0.1:9119/api/status — the Hermes dashboard's public status
    (gateway state, per-platform metrics: requests, messages, tokens today)
  * <data>/scripts/allowance-report.py --json — the OpenCode Go quota report
    (today's spend, monthly/weekly percentages, days left)
  * <data>/cron/jobs.json — the scheduled jobs

Served to the tailnet so the desktop apps (agent-watch) can render it without
tunnels or keys. Everything is read-only; nothing leaves the host.
"""
from __future__ import annotations

import json
import os
import subprocess
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DATA = os.environ.get("HERMES_DATA", "/var/lib/hermes")
BIND = os.environ.get("HERMES_STATUS_BIND", "127.0.0.1")
PORT = int(os.environ.get("HERMES_STATUS_PORT", "8099"))
CACHE_SECONDS = float(os.environ.get("HERMES_STATUS_CACHE", "10"))

_lock = threading.Lock()
_cache: dict[str, object] = {"at": 0.0, "body": b"{}"}


def _run(cmd: list[str], timeout: float = 30) -> str:
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return out.stdout
    except Exception:
        return ""


def allowance() -> dict:
    # the report lives in the container, where its paths and keys are
    raw = _run(["docker", "exec", "hermes", "python3", "/opt/data/scripts/allowance-report.py", "--json"], 60)
    try:
        return json.loads(raw)
    except Exception:
        return {}


def dashboard() -> dict:
    try:
        with urllib.request.urlopen("http://127.0.0.1:9119/api/status", timeout=3) as r:
            return json.load(r)
    except Exception:
        return {}


def cron() -> dict:
    try:
        with open(f"{DATA}/cron/jobs.json") as f:
            doc = json.load(f)
    except Exception:
        return {}
    jobs = doc.get("jobs", doc) if isinstance(doc, dict) else doc
    items = list(jobs.values()) if isinstance(jobs, dict) else list(jobs or [])
    enabled = [j for j in items if isinstance(j, dict) and j.get("enabled", True)]
    return {
        "total": len(items),
        "enabled": len(enabled),
        "names": [j.get("name", "?") for j in enabled][:10],
    }


def build() -> dict:
    d = dashboard()
    platforms = {}
    tokens = requests = active = 0
    for name, info in (d.get("gateway_platforms") or {}).items():
        if not isinstance(info, dict):
            continue
        platforms[name] = info.get("state")
        m = info.get("metrics") or {}
        today = m.get("metrics_today") or {}
        tokens += int(today.get("tokens") or 0)
        requests += int(today.get("requests") or 0)
        active += int(m.get("active_runs") or 0)
    return {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "hermes": {
            "version": d.get("version"),
            "gateway": d.get("gateway_state"),
            "platforms": platforms,
            "tokens_today": tokens,
            "requests_today": requests,
            "active_runs": active,
        },
        "allowance": allowance(),
        "cron": cron(),
    }


def cached() -> bytes:
    now = time.time()
    with _lock:
        if now - float(_cache["at"]) < CACHE_SECONDS:
            return _cache["body"]  # type: ignore[return-value]
    body = json.dumps(build()).encode()
    with _lock:
        _cache["at"] = now
        _cache["body"] = body
    return body


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        if self.path.split("?")[0] not in ("/status", "/", "/api/status"):
            self.send_error(404)
            return
        body = cached()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args) -> None:  # quiet
        pass


if __name__ == "__main__":
    ThreadingHTTPServer((BIND, PORT), Handler).serve_forever()
