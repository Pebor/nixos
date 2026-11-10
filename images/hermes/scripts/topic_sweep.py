#!/opt/hermes/.venv/bin/python
"""Cron sweeper for Telegram DM topics — thin CLI over the telegram-topic-cleaner plugin.

Usage: topic_sweep.py [days] [--apply]
  days    idle threshold in days (default from the plugin: 14)
  --apply actually delete; without it the run is a dry run

Prints a short report; prints nothing (silent) when there is nothing to delete.
"""
from __future__ import annotations

import importlib.util
import os
import sys
from pathlib import Path

# The plugin ships bundled in the image tree and the user-dir copy is retired by
# 03-hermes-local, so resolve BOTH: hardcoding only $HERMES_HOME/plugins made the
# sweep die with FileNotFoundError for a week (2026-10-28 -> 11-02).
PLUGIN_CANDIDATES = [
    Path(os.getenv("HERMES_HOME", "/opt/data")) / "plugins" / "telegram-topic-cleaner" / "__init__.py",
    Path("/opt/hermes/plugins/telegram-topic-cleaner/__init__.py"),
]
PLUGIN = next((p for p in PLUGIN_CANDIDATES if p.is_file()), PLUGIN_CANDIDATES[0])
CHAT = os.getenv("TOPIC_CLEANER_CHAT", "1785855177")
# thread this job is allowed to speak in stays protected via TOPIC_CLEANER_PROTECT


def load():
    spec = importlib.util.spec_from_file_location("topic_cleaner", PLUGIN)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main(argv: list[str]) -> int:
    days = None
    apply = False
    for a in argv:
        if a in ("--apply", "--yes"):
            apply = True
        elif a.replace(".", "", 1).isdigit():
            days = float(a)
    tc = load()
    days = days if days is not None else tc.keep_days()
    protect = os.getenv("HERMES_SESSION_THREAD_ID") or os.getenv("CRON_TOPIC_THREAD_ID")
    res = tc.sweep(CHAT, days=days, dry_run=not apply, protect_thread=protect)
    if not res["topics"]:
        return 0  # silent: nothing idle enough to touch
    print(tc.report_sweep(res))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
