# valheim-llyfr-notify — "Llyfr je ve hře" notifikace na t14.
#
# Proč: Pebor chce vědět, kdy Llyfr začne hrát Valheim, aby se mohl připojit.
# Vanilla server nemá admin API, ale log dedicated serveru obsahuje při každém
# připojení klienta dva řádky:
#   Got connection SteamID <id>
#   Got handshake from client <id>
# a při odpojení `Closing socket <id>`. Watcher je hloupý `docker logs -f`
# filtr na Llyfrův SteamID — žádný LLM, žádný RCON, žádné heslo, nulové náklady.
#
# Doručení: ssh na t14 (Noctalia notification daemon) + DBus session bus;
# `-t 0` = notifikace nevyprší, takže ji uvidí i když zrovna není u stroje.
# Když je t14 uspaný/nedostupný, zkouší to znovu (RETRIES × RETRY_GAP) a pak
# to vzdá — notifikace o hodinu staré hře nemá cenu.
#
# Cooldown MIN_GAP řeší reconnecty: Valheim klient se po výpadku handshakuje
# znovu, ale to není "začal hrát" a nemá to pípat pořád.
#
# Test ručně (notifikace se objeví na t14):
#   sudo -u server $(systemctl show -p ExecStart --value valheim-llyfr-notify \
#     | sed -E 's/.*path=([^ ;]+).*/\1/') --line "Got handshake from client 76561198111243168"
# Log: journalctl -u valheim-llyfr-notify -f
{
  flake.modules.nixos.valheim-llyfr-notify =
    { pkgs, ... }:
    let
      watcher = pkgs.writeShellScript "valheim-llyfr-notify" ''
        set -uo pipefail

        CONTAINER=valheim
        LLYFR_STEAMID=76561198111243168
        T14=pebor@100.86.253.100
        MIN_GAP=600       # cooldown mezi notifikacemi (s)
        RETRIES=4         # pokusy o doručení, když t14 nespí/neslyší
        RETRY_GAP=60      # pauza mezi pokusy (s)
        last_notify=-100  # první join projde vždy

        log() { printf '%s valheim-llyfr-notify: %s\n' "$(date -Is)" "$*"; }

        notify_t14() {
          timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=5 "$T14" bash -s -- "$1" "$2" <<'REMOTE'
        title=$1; body=$2
        export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
        command -v notify-send >/dev/null 2>&1 || export PATH="$HOME/.nix-profile/bin:$PATH"
        exec notify-send -a Valheim -i applications-games -u normal -t 0 "$title" "$body"
        REMOTE
        }

        deliver() {
          local i
          for ((i = 1; i <= RETRIES; i++)); do
            if notify_t14 "$1" "$2"; then
              log "notifikace doručena na t14 (pokus $i)"
              return 0
            fi
            log "t14 nedostupny (pokus $i/$RETRIES)"
            sleep "$RETRY_GAP"
          done
          log "notifikace se nedorucila: t14 byl $(( RETRIES * RETRY_GAP / 60 )) min mimo"
          return 1
        }

        on_join() {
          local now=$SECONDS
          if (( last_notify >= 0 && now - last_notify < MIN_GAP )); then
            log "handshake ignorovan (cooldown, pred $(( now - last_notify ))s)"
            return 0
          fi
          last_notify=$now
          log "Llyfr se pripojil -> notifikace na t14"
          # na pozadí, aby retry nezablokoval čtení logu (odchod/nový join)
          deliver "Valheim" "Llyfr je ve hře 🎮" &
        }

        if [ "''${1:-}" = "--line" ]; then
          case "''${2:-}" in
            *"Got handshake from client $LLYFR_STEAMID"*) on_join ;;
            *) log "testovaci radek neni join Llyfra: ''${2:-<prazdno>}" ;;
          esac
          wait
          exit 0
        fi

        log "starting (container=$CONTAINER, llyfr=$LLYFR_STEAMID)"
        while :; do
          docker logs -f --since 1s "$CONTAINER" 2>&1 | while IFS= read -r line; do
            case $line in
              *"Got handshake from client $LLYFR_STEAMID"*) on_join ;;
            esac
          done
          # `docker logs -f` skončí, když se kontejner restartuje — navázat
          log "log stream skoncil, restart za 5s"
          sleep 5
        done
      '';
    in
    {
      systemd.services.valheim-llyfr-notify = {
        description = "Valheim: notifikace na t14, kdyz se Llyfr pripoji";
        wantedBy = [ "multi-user.target" ];
        after = [ "docker.service" "network-online.target" ];
        requires = [ "docker.service" ];
        wants = [ "network-online.target" ];
        path = with pkgs; [
          docker
          coreutils
          bash
          openssh
        ];
        serviceConfig = {
          ExecStart = "${watcher}";
          Restart = "always";
          RestartSec = "10s";
          User = "server";
        };
      };
    };
}
