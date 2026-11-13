#!/usr/bin/env bash
# valheim-presence — kdo je ve Valheimu, pro monitorovací tab v tasks-app.
#
# Proč: Pebor chce na jedné obrazovce vidět, jestli si Llyfr (bratr) zrovna hraje.
# Vanilla Valheim nemá admin API a jeho query port neodpovídá na A2S dotaz
# (změřeno 13. 11. 2026 — timeout i z localhostu na VPS), takže jediný signál je
# log dedicated serveru:
#
#   Got connection SteamID <id>       klient se připojil
#   Got handshake from client <id>    totéž, jiná cesta (reconnect)
#   Got character ZDOID from <name>   hráč se zjevil ve světě → jméno k id
#   Closing socket <id>               odpojení
#   ... Connections <n> ZDOS:...      každých 10 min; n = 0 je self-healing reset
#
# Server jede na VPS (od 1. 11. 2026), takže skript streamuje `docker logs -f`
# přes ssh a drží stav v paměti. Po každé změně — a jako heartbeat každé 4 minuty —
# přepíše /home/server/tasks-api/data/valheim-presence.json; ten soubor servíruje
# tasks-api appce na /api/v1/status. Žádné hlasování v intervalu: stav se mění
# jen z logu, interval je pouze heartbeat, aby byla vidět čerstvost.
#
# Test: systemctl status valheim-presence && cat ~/tasks-api/data/valheim-presence.json
# Simulace joinu: echo 'Got connection SteamID 76561198111243168' | bash valheim-presence.sh --line

set -uo pipefail

STATE=${VALHEIM_PRESENCE_FILE:-/home/server/tasks-api/data/valheim-presence.json}
VPS=${VALHEIM_VPS:-pebor@100.117.69.56}
SSH_PORT=${VALHEIM_SSH_PORT:-1234}
CONTAINER=${VALHEIM_CONTAINER:-valheim}
HEARTBEAT=240   # bez řádku z logu přepiš stav, ať je na appce vidět, že watcher žije

declare -A ONLINE=()   # steamid -> 1 (přítomen ve hře)
declare -A NAME=(
  [76561198111243168]=Llyfr
  [76561198112146150]=Pebor
)
SERVER_UP=false
LAST_CONN=""

log() { printf '%s valheim-presence: %s\n' "$(date -Is)" "$*"; }

ssh_vps() {
  timeout 40 ssh -o BatchMode=yes -o ConnectTimeout=8 -p "$SSH_PORT" "$VPS" "$@"
}

# Jeden zdroj pravdy pro appku: soubor se vždy přepisuje celý a atomicky, nikdy se neappenduje.
write_state() {
  local players="" ids="" id name count llyfr=false
  for id in "${!ONLINE[@]}"; do
    name=${NAME[$id]:-hráč}
    players+="${players:+, }\"$name\""
    ids+="${ids:+, }\"$id\""
  done
  count=${#ONLINE[@]}
  if [ -n "${ONLINE[76561198111243168]:-}" ]; then llyfr=true; fi
  printf '{"updated_at": %s, "server_up": %s, "llyfr_online": %s, "connections": %d, "players": [%s], "player_ids": [%s]}\n' \
    "$(date +%s)" "$SERVER_UP" "$llyfr" "$count" "$players" "$ids" > "$STATE.tmp" \
    && mv "$STATE.tmp" "$STATE"
}

handle() {
  local line=$1 id name n
  case $line in
    *"Got connection SteamID "*)
      id=${line##*Got connection SteamID }
      id=${id%%[!0-9]*}
      [ -n "$id" ] || return 0
      ONLINE[$id]=1
      LAST_CONN=$id
      log "pripojen $id (${NAME[$id]:-neznamy})"
      write_state
      ;;
    *"Got handshake from client "*)
      id=${line##*Got handshake from client }
      id=${id%%[!0-9]*}
      [ -n "$id" ] || return 0
      ONLINE[$id]=1
      LAST_CONN=$id
      write_state
      ;;
    *"Got character ZDOID from "*)
      # Jméno hráče, které server zná ze světa — doplní se k poslednímu připojenému id.
      name=${line##*Got character ZDOID from }
      name=${name%% *}
      if [ -n "$LAST_CONN" ] && [ -n "$name" ] && [ -z "${NAME[$LAST_CONN]:-}" ]; then
        NAME[$LAST_CONN]=$name
        write_state
      fi
      ;;
    *"Closing socket "*)
      id=${line##*Closing socket }
      id=${id%%[!0-9]*}
      [ -n "$id" ] || return 0
      unset "ONLINE[$id]"
      log "odpojen $id (${NAME[$id]:-neznamy})"
      write_state
      ;;
    *"Connections "*)
      # Periodická pravda serveru: nula znamená nikdo tam není. Kryje i případy, kdy
      # nám utekl Closing socket (restart klienta, pád hry).
      n=${line##*Connections }
      n=${n%% *}
      if [[ $n =~ ^[0-9]+$ ]] && [ "$n" = "0" ] && [ ${#ONLINE[@]} -gt 0 ]; then
        log "server hlasi 0 spojeni — cistim stav"
        ONLINE=()
        write_state
      fi
      ;;
  esac
}

if [ "${1:-}" = "--line" ]; then
  SERVER_UP=true
  handle "${2:-}"
  cat "$STATE"
  exit 0
fi

mkdir -p "$(dirname "$STATE")"
log "start (state=$STATE, vps=$VPS:$SSH_PORT, heartbeat=${HEARTBEAT}s)"

while :; do
  running=$(ssh_vps "docker inspect -f '{{.State.Running}}' $CONTAINER" 2>/dev/null | tr -d '\r\n')
  if [ "$running" != "true" ]; then
    log "valheim na VPS neběží / VPS neodpovídá ('${running:-nic}')"
    SERVER_UP=false
    ONLINE=()
    write_state
    sleep 20
    continue
  fi
  SERVER_UP=true
  # Seed po restartu watcheru: poslední známý počet spojení, aby neviselo "Llyfr hraje" z minula.
  seed=$(ssh_vps "docker logs --tail 400 $CONTAINER 2>&1 | grep -o 'Connections [0-9]*' | tail -1" 2>/dev/null | tr -d '\r')
  case $seed in
    "Connections 0") ONLINE=() ;;
  esac
  write_state
  log "streamuju log (seed='${seed:-?}')"

  exec 3< <(ssh -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=30 -o ServerAliveCountMax=4 \
      -p "$SSH_PORT" "$VPS" "docker logs -f --since 1s $CONTAINER" 2>&1)
  SSH_PID=$!

  while :; do
    if IFS= read -r -t "$HEARTBEAT" -u 3 line; then
      handle "$line"
      continue
    fi
    rc=$?
    if (( rc > 128 )); then
      # Timeout = jen heartbeat. Pokud ssh mezitím umřel, spojení obnovit.
      if ! kill -0 "$SSH_PID" 2>/dev/null; then break; fi
      write_state
      continue
    fi
    break
  done
  exec 3<&-

  log "log stream skoncil (restart serveru nebo ssh) — obnovuju"
  SERVER_UP=false
  ONLINE=()
  write_state
  sleep 10
done
