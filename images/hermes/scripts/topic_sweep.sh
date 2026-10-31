#!/usr/bin/env bash
# Wrapper so the cron engine (which runs with its own interpreter) still uses the
# hermes venv, which is where the plugin's dependencies live.
set -uo pipefail
exec /opt/hermes/.venv/bin/python /opt/data/scripts/topic_sweep.py "$@"
