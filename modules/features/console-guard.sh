set -u

# Fail loudly instead of silently doing nothing when the unit's PATH is wrong
# (2026-10-28: "awk: command not found" made the whole guard a no-op).
for tool in loginctl awk date grep; do
  command -v "$tool" >/dev/null 2>&1 || { echo "console-guard: chybí $tool v PATH" >&2; exit 2; }
done

# Kill a LOCAL console session that should not be readable by whoever walks by.
# Only seat0/no-remote sessions are touched: the SSH session this agent runs
# over, and every container session, has no seat and is never a candidate.

dry=0
idle_limit=${CONSOLE_IDLE_SECONDS:-1800}
if [ "${1:-}" = "--dry-run" ]; then
  dry=1
fi

lid_closed=0
for f in /proc/acpi/button/lid/*/state; do
  [ -r "$f" ] || continue
  if grep -q closed "$f"; then
    lid_closed=1
  fi
done

now=$(date +%s)
rc=0

for s in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
  seat=$(loginctl show-session "$s" -p Seat --value 2>/dev/null || true)
  remote=$(loginctl show-session "$s" -p Remote --value 2>/dev/null || true)
  [ "$seat" = "seat0" ] || continue
  [ "$remote" = "no" ] || continue

  tty=$(loginctl show-session "$s" -p TTY --value 2>/dev/null || true)
  user=$(loginctl show-session "$s" -p Name --value 2>/dev/null || true)
  idle_hint=$(loginctl show-session "$s" -p IdleHint --value 2>/dev/null || true)
  idle_since=$(loginctl show-session "$s" -p IdleSinceHint --value 2>/dev/null || true)

  idle_for=0
  case "$idle_since" in
    ''|*[!0-9]*) idle_for=0 ;;
    *) if [ "$idle_hint" = "yes" ]; then idle_for=$(( now - idle_since / 1000000 )); fi ;;
  esac

  why=""
  if [ "$lid_closed" = "1" ]; then
    why="lid closed"
  elif [ "$idle_for" -ge "$idle_limit" ]; then
    why="idle ${idle_for}s (limit ${idle_limit}s)"
  fi
  [ -n "$why" ] || continue

  if [ "$dry" = "1" ]; then
    printf 'would terminate session %s (%s on %s): %s\n' "$s" "$user" "${tty:-?}" "$why"
  else
    printf 'terminating session %s (%s on %s): %s\n' "$s" "$user" "${tty:-?}" "$why"
    loginctl terminate-session "$s" || rc=1
  fi
done

exit $rc
