#!/usr/bin/env python3
"""thought-sink — thoughts sent through pebor.me, delivered on this machine.

One long-lived SSE connection to the site's API. Two jobs, one socket:

  * every thought arrives over it, so a message sent while this box was asleep
    is replayed from the persisted id instead of being lost;
  * the connection itself is the "laptop online" signal the public page shows —
    the server infers presence from it, this script never polls.

Delivery is Telegram first (works with the laptop shut) and a desktop toast on
the T14 second (best effort, dropped when that machine is off).
"""
from __future__ import annotations

import json
import os
import shlex
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

API = os.environ.get("THOUGHT_API", "https://pebor.me").rstrip("/")
TOKEN = os.environ.get("THOUGHT_TOKEN", "")
STATE_DIR = Path(os.environ.get("THOUGHT_STATE_DIR", "/var/lib/hermes/var/thought-sink"))
HERMES = os.environ.get("THOUGHT_HERMES_BIN", "/var/lib/hermes-native/hermes-agent/.hermes/bin/hermes")
CHAT = os.environ.get("THOUGHT_CHAT", "telegram:1785855177")
DESKTOP = os.environ.get("THOUGHT_DESKTOP", "pebor@100.86.253.100")
LAST = STATE_DIR / "last_id"


def log(message: str) -> None:
    print(f"thought-sink: {message}", flush=True)


def read_last() -> int:
    try:
        return int(LAST.read_text().strip())
    except (OSError, ValueError):
        return 0


def write_last(value: int) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = LAST.with_suffix(".tmp")
    tmp.write_text(str(value))
    tmp.replace(LAST)


def telegram(text: str) -> None:
    # HERMES_HOME, not HOME: the CLI resolves its config and .env from
    # HERMES_HOME, and HOME=/var/lib/hermes made it look in .hermes/ and
    # report "platform telegram is not configured".
    env = {**os.environ, "HERMES_HOME": "/var/lib/hermes"}
    subprocess.run([HERMES, "send", "-t", CHAT, text],
                   env=env, timeout=60, check=False, stdin=subprocess.DEVNULL,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    log("telegram sent")


def desktop(text: str) -> None:
    """A toast on the T14 — the same recipe battery-guard and desktop-notify use."""
    command = (
        "export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus; "
        "export WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-1}; "
        "export DISPLAY=${DISPLAY:-:0}; "
        'export PATH="$HOME/.nix-profile/bin:/run/current-system/sw/bin:$PATH"; '
        f"notify-send -u normal -t 8000 -a 'pebor.me' -i dialog-information "
        f"{shlex.quote('a thought for you')} {shlex.quote(text)}"
    )
    try:
        subprocess.run(
            ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new",
             "-o", "ConnectTimeout=4", DESKTOP, "bash -s"],
            input=command.encode(), timeout=12, check=False,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        log("desktop toast attempted")
    except (subprocess.SubprocessError, OSError) as exc:
        log(f"desktop toast skipped: {exc}")


def deliver(thought: dict) -> None:
    text = "💭 " + str(thought.get("message", "")).strip()
    log(f"thought {thought.get('id')}: delivering")
    telegram(text)
    desktop(text)
    write_last(int(thought.get("id", 0)))


def stream() -> None:
    since = read_last()
    url = f"{API}/api/thoughts/stream?since={since}"
    # A real User-Agent: the site sits behind Cloudflare, which 403s the
    # default python-urllib fingerprint.
    request = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {TOKEN}",
        "Accept": "text/event-stream",
        "User-Agent": "pebor-thought-sink/1.0 (+https://pebor.me)",
    })
    with urllib.request.urlopen(request, timeout=120) as response:
        log(f"connected, replaying after id {since}")
        event = None
        for raw in response:
            line = raw.decode("utf-8", "replace").rstrip("\n")
            if line.startswith("event:"):
                event = line[6:].strip()
            elif line.startswith("data:") and event:
                try:
                    payload = json.loads(line[5:].strip())
                except ValueError:
                    payload = None
                if event == "thought" and payload:
                    deliver(payload)
                event = None
            elif line.startswith(":") and "keepalive" in line:
                log("keepalive")


def main() -> int:
    if len(TOKEN) < 16:
        log("THOUGHT_TOKEN missing — refusing to run")
        return 1
    backoff = 2
    while True:
        try:
            stream()
            backoff = 2
        except urllib.error.HTTPError as exc:
            log(f"HTTP {exc.code} — backing off {backoff}s")
            if exc.code == 401:
                log("token rejected; check THOUGHT_TOKEN")
                return 1
        except Exception as exc:  # noqa: BLE001 — a listener must never die
            log(f"{type(exc).__name__}: {exc} — backing off {backoff}s")
        time.sleep(backoff)
        backoff = min(backoff * 2, 60)


if __name__ == "__main__":
    sys.exit(main())
