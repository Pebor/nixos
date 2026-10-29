# valheim-chat-watcher — most mezi herním chatem a agentem.
#
# Hráči píšou do Valheim chatu; QoL plugin (server-side) každou zprávu zapíše
# do logu serveru jako `Chat: <hráč>: <text>`. Tenhle watcher je hloupý filtr:
# sleduje `docker logs -f valheim` a když zpráva začíná na `hermes:`, předá
# slovo agentovi (`hermes chat -q`), který odpoví zpátky do hry přes RCON.
#
# Záměrně to NENÍ LLM smyčka: watcher sám nespotřebuje žádné tokeny, probudí
# agenta jen ve chvíli, kdy ho hráč osloví. Jeden běh = jedna odpověď.
# Test ručně: systemctl stop valheim-chat-watcher
#             sudo -u server $(systemctl show -p ExecStart --value valheim-chat-watcher \
#               | sed -E 's/.*path=([^ ;]+).*/\1/') --line "Chat: Pebor: hermes: test"
{
  flake.modules.nixos.valheim-chat-watcher =
    { pkgs, ... }:
    let
      watcher = pkgs.writeShellScript "valheim-chat-watcher" ''
        set -uo pipefail

        CONTAINER=valheim
        HERMES=/run/current-system/sw/bin/hermes
        AGENT_LOG=/tmp/valheim-chat-agent.log
        MIN_GAP=20
        last_run=-100   # první zpráva projde vždy

        log() { printf '%s valheim-chat-watcher: %s\n' "$(date -Is)" "$*"; }

        build_prompt() {
          local who=$1 text=$2 tpl
          tpl='Jsi Hermes, agent na t490s. Tohle vyvolal hráč ve hře Valheim, ne Telegram.

        Hráč "@@WHO@@" napsal do herního chatu:
        @@TEXT@@

        Odpověz mu do herního chatu. RCON heslo najdeš na hostu v souboru
        ~/valheim/config/bepinex/config/org.tristan.rcon.cfg (řádek Password = ...),
        přes ssh server@host.docker.internal. Pak:
        VALHEIM_RCON_HOST=100.103.136.50 VALHEIM_RCON_PASS=<heslo> /opt/data/bin/valheim_rcon.py "say <odpověď>"

        Pravidla: česky, maximálně 2 krátké věty (herní chat). Svět neměň (nedávej
        itemy, neteleportuj, nespouštěj eventy), pokud o to hráč výslovně nepožádá.
        Když dotaz potřebuje dlouhou odpověď, napiš do chatu že to řešíš a detaily
        pošli na Telegram.'
          tpl=''${tpl//@@WHO@@/$who}
          printf '%s' "''${tpl//@@TEXT@@/$text}"
        }

        handle() {
          local who=$1 text=$2 prompt rc
          if (( last_run >= 0 && SECONDS - last_run < MIN_GAP )); then
            log "throttled: $who: $text"
            return 0
          fi
          last_run=$SECONDS
          prompt=$(build_prompt "$who" "$text")
          log "waking agent for $who: $text"
          # lane session (valheim) — při přetečení nejdřív handoff do memory, pak rotace
          handoff=$(docker exec hermes /usr/local/bin/python3 /opt/data/scripts/lane-session.py --handoff-if-full valheim 250 2>/dev/null || true)
          if [ -n "$handoff" ]; then
            prompt="$prompt

$handoff"
            log "lane session full -> handoff + rotate"
          fi
          timeout 300 "$HERMES" chat -q "$prompt" -c valheim --create-if-missing >>"$AGENT_LOG" 2>&1
          rc=$?
          if [ -n "$handoff" ]; then
            docker exec hermes /usr/local/bin/python3 /opt/data/scripts/lane-session.py --rotate valheim >/dev/null 2>&1 || true
          fi
          log "agent finished for $who (rc=$rc)"
        }

        if [ "''${1:-}" = "--line" ]; then
          line=$2
          rest=''${line#*Chat: }
          handle "''${rest%%: *}" "''${rest#*: }"
          exit 0
        fi

        log "starting (container=$CONTAINER)"
        while :; do
          docker logs -f --since 1s "$CONTAINER" 2>&1 | while IFS= read -r line; do
            case $line in
              *"Chat: "*) ;;
              *) continue ;;
            esac
            rest=''${line#*Chat: }
            who=''${rest%%: *}
            msg=''${rest#*: }
            [ "$who" = "$msg" ] && continue
            case $who in Server|Hermes|"") continue ;; esac
            shopt -s nocasematch
            if [[ $msg =~ ^hermes[[:space:]:,.-] ]]; then
              body=''${msg:6}
              body=''${body#"''${body%%[![:space:]:,.-]*}"}
              [ -n "$body" ] && handle "$who" "$body"
            fi
            shopt -u nocasematch
          done
          sleep 5
        done
      '';
    in
    {
      systemd.services.valheim-chat-watcher = {
        description = "Valheim chat -> agent bridge (zprava zacinajici na 'hermes:')";
        wantedBy = [ "multi-user.target" ];
        after = [ "docker.service" "network-online.target" ];
        requires = [ "docker.service" ];
        wants = [ "network-online.target" ];
        path = with pkgs; [ docker coreutils bash ];
        serviceConfig = {
          ExecStart = "${watcher}";
          Restart = "always";
          RestartSec = "5s";
          User = "server";
        };
      };
    };
}
