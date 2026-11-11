#!/run/current-system/sw/bin/bash
# Runs once after every boot (systemd oneshot). Proves the machine came back:
# waits for the agent units, counts containers, probes the hostnames, and sends
# ONE Telegram line from the host itself — independent of the agent being alive.
set -uo pipefail
export PATH=/run/current-system/sw/bin:/usr/bin:/bin

LOG=/home/server/.postboot.log
: > "$LOG"
say() { echo "$*" >> "$LOG"; }

say "=== boot verify $(date -Is) ==="

# 1. wait (max 180 s) for the gateway to actually answer — `is-active` alone
#    reports the process, not a bound port, and the first boot log claimed
#    "000" because it asked before the socket was listening.
for i in $(seq 1 90); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8642/health 2>/dev/null)
  [ "$code" = "200" ] && break
  sleep 2
done
say "hermes-native: $(systemctl is-active hermes-native 2>/dev/null) (health 200 after ~$((i*2))s)"
say "dashboard:     $(systemctl is-active hermes-dashboard 2>/dev/null)"
say "gateway /health: $code"

# 2. give containers a moment, then count
sleep 10
up=$(docker ps -q 2>/dev/null | wc -l)
all=$(docker ps -aq 2>/dev/null | wc -l)
say "containers up/total: $up/$all"

# 3. hostnames
ok=0; bad=""
for u in cloud tasks calendar cal chat demo ai.dash mon annotate office fin; do
  c=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 6 "https://$u.pebor.me/" 2>/dev/null)
  case "$c" in 200|302) ok=$((ok+1));; *) bad="$bad $u:$c";; esac
done
say "hostnames ok: $ok/11${bad:+ (bad:$bad)}"

# 4. failures
failed=$(systemctl --failed --no-legend --no-pager 2>/dev/null | wc -l)
say "failed units: $failed"
df -h / | tail -1 | awk '{print "disk: "$5" used, "$4" free"}' >> "$LOG"

# 5. one Telegram line, straight from the host (no agent involved)
TOKEN=$(grep -m1 '^TELEGRAM_BOT_TOKEN=' /var/lib/hermes/.env | cut -d= -f2-)
CHAT=$(grep -m1 '^TELEGRAM_HOME_CHANNEL=' /var/lib/hermes/.env | cut -d= -f2-)
if [ -n "${TOKEN:-}" ] && [ -n "${CHAT:-}" ]; then
  msg="🔄 t490s reboot: hermes $(systemctl is-active hermes-native) · kontejnery $up/$all · domény $ok/11 · failed units $failed${bad:+ · ⚠$bad}"
  curl -s -o /dev/null --max-time 15 \
    -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
    -d "chat_id=$CHAT" --data-urlencode "text=$msg" >> "$LOG" 2>&1
  say "telegram: sent"
else
  say "telegram: NO TOKEN/CHAT in .env"
fi
say "=== done $(date -Is) ==="
