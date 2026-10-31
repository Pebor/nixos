#!/usr/bin/env bash
# Daily topic sweep: delete Telegram DM topics idle for the configured keep_days
# ($HERMES_HOME/topic-cleaner.json, currently 5) while protecting the Cron topic and
# anything listed there. Silent when there is nothing to delete.
set -uo pipefail
exec /opt/hermes/.venv/bin/python /opt/data/scripts/topic_sweep.py --apply
