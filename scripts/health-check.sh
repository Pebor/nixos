#!/usr/bin/env bash
# Deterministic health check for the native Hermes gateway + Docker sandbox.
# Runs on the HOST as `server`; no LLM, no secrets printed.
set -uo pipefail

PASS=0
FAIL=0
pass() { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }

lock=/var/lib/hermes/state/health-check.lock
mkdir -p "$(dirname "$lock")"
exec 9>"$lock"
flock -n 9 || { echo "another health check is running"; exit 2; }

# 1. Units
for unit in hermes-native hermes-dashboard hermes-plugins-deploy; do
  if systemctl is-active --quiet "$unit"; then
    pass "unit $unit active"
  else
    bad "unit $unit not active"
  fi
done

# 2. The live gateway sandbox (not a manual probe)
cid=$(docker ps -q --filter label=hermes-agent=1 | head -1)
if [ -z "$cid" ]; then
  bad "no hermes-agent sandbox container"
else
  pass "sandbox container ${cid:0:12}"

  uid=$(docker exec "$cid" id -u 2>/dev/null || true)
  [ "$uid" = "1001" ] && pass "sandbox uid 1001" || bad "sandbox uid=$uid (want 1001)"

  docker exec "$cid" test -f /.dockerenv 2>/dev/null \
    && pass "sandbox is a container" || bad "sandbox is not a container"

  docker exec "$cid" test -r /var/lib/hermes/.env 2>/dev/null \
    && pass "sandbox reads .env" || bad "sandbox cannot read .env"

  docker exec "$cid" test ! -r /var/lib/hermes/secrets.env 2>/dev/null \
    && pass "secrets.env is masked" || bad "secrets.env is readable in sandbox"

  docker exec "$cid" ssh -o BatchMode=yes -o ConnectTimeout=5 server@127.0.0.1 true 2>/dev/null \
    && pass "sandbox ssh to host" || bad "sandbox ssh to host"

  docker exec "$cid" docker ps -q >/dev/null 2>&1 \
    && pass "sandbox docker access" || bad "sandbox docker access"

  if docker exec "$cid" sh -c 'echo health > /home/server/.hermes-health-write' 2>/dev/null; then
    own=$(stat -c '%u:%g' /home/server/.hermes-health-write 2>/dev/null || true)
    [ "$own" = "1001:100" ] && pass "sandbox write to /home/server as 1001:100" \
      || bad "sandbox write owner=$own (want 1001:100)"
    rm -f /home/server/.hermes-health-write
  else
    bad "sandbox cannot write to /home/server"
  fi
fi

# 3. Gateway API + dashboard
api=$(curl -sS --max-time 8 http://127.0.0.1:8642/health 2>/dev/null || true)
if printf '%s' "$api" | grep -q '"status"'; then
  ver=$(printf '%s' "$api" | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
  pass "gateway API 200 (version ${ver:-unknown})"
else
  bad "gateway API not healthy: ${api:0:120}"
fi

dash=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:9119/ 2>/dev/null || true)
[ "$dash" = "302" ] || [ "$dash" = "200" ] \
  && pass "dashboard :9119 ($dash)" || bad "dashboard :9119 returned $dash"

# 4. Edge hostnames through Caddy
for url in https://chat.pebor.me/ https://demo.pebor.me/inbox/ https://ai.dash.pebor.me/ https://cloud.pebor.me/; do
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || true)
  case "$code" in
    200|301|302|401|403) pass "edge $url ($code)" ;;
    *) bad "edge $url returned ${code:-000}" ;;
  esac
done

# 5. Plugins deployed
for p in allowance-ledger desktop-notify reasoning-now telegram-topic-cleaner; do
  if [ -f "/var/lib/hermes/plugins/$p/plugin.yaml" ] || [ -f "/var/lib/hermes/plugins/$p/__init__.py" ]; then
    pass "plugin $p present"
  else
    bad "plugin $p missing"
  fi
done

# 6. Tasks API + board read (key never printed)
keyf=/home/server/tasks-api/.env
if [ -r "$keyf" ]; then
  key=$(grep -m1 '^TASKS_API_KEY=' "$keyf" | cut -d= -f2-)
  key=${key%\"}; key=${key#\"}
  tcode=$(curl -s -o /tmp/tasks-health.json -w '%{http_code}' --max-time 8 \
    -H "X-API-Key: $key" http://127.0.0.1:8001/api/v1/boards 2>/dev/null || true)
  [ "$tcode" = "200" ] && pass "tasks API /boards 200" || bad "tasks API /boards returned $tcode"
else
  bad "tasks API key file missing"
fi

# 7. TTS provider is present in config (actual synthesis is a separate check)
tts=$(/run/current-system/sw/bin/hermes config get tts.provider 2>/dev/null | tail -1 || true)
[ -n "$tts" ] && pass "tts.provider=$tts" || bad "tts.provider not readable"

printf '\nRESULT: pass=%d fail=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
