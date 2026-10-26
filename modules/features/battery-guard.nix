# battery-guard — never lose the pack (and the server) in silence again.
#
# 2026-10-26: the charger was accidentally knocked out of the t490s and
# nothing warned anyone — no upower, no battery sampler, and sleep/hibernate
# are disabled on purpose. The box drained quietly and died mid-write at
# 01:55 CET; the journal had no record of when AC went away, which is exactly
# the gap this module closes.
#
# Every 2 min a plain shell (no LLM anywhere in the path) reads BAT0:
#   - alerts once per threshold as the pack falls: 65 / 50 / 35 / 20 / 10 / 5 %
#   - primary target is the t14 — an *urgent* desktop notification
#   - if the t14 is suspended/unreachable: a Telegram DM to Pebor
#   - one "back on AC" Telegram line closes the loop
#   - a journal line per status change / 10 % band, so the next postmortem
#     has a trail instead of arithmetic
#
# Two aspects:
#   battery-guard        — the timer + the script (imported by t490s-server)
#   battery-guard-target — lets the t490s key pop that notification on a
#                          graphical host (imported by t14)
{ ... }:
{
  flake.modules.nixos.battery-guard = { pkgs, lib, ... }:
    let
      # Plain shell, deliberately not writeShellApplication: no shellcheck gate
      # in the middle of a safety net.
      script = pkgs.writeShellScriptBin "battery-guard" ''
        export PATH="${lib.makeBinPath [ pkgs.openssh pkgs.curl pkgs.coreutils pkgs.gnugrep pkgs.gnused ]}:$PATH"
        set -u
        BAT=''${BAT_PATH:-/sys/class/power_supply/BAT0}
        STATE=''${STATE_DIR:-/var/lib/battery-guard}
        SECRETS=/var/lib/hermes/secrets.env   # master copy (root:users 0440)
        T14=pebor@100.86.253.100              # tailnet IP: no DNS in the way
        CHAT=1785855177                       # Pebor's DM
        THRESHOLDS="65 50 35 20 10 5"

        log() { printf 'battery-guard: %s\n' "$*"; }

        if [ ! -r "$BAT/capacity" ]; then
          log "no BAT0 — nothing to watch"
          exit 0
        fi
        cap=$(cat "$BAT/capacity")
        status=$(cat "$BAT/status")
        ac=$(cat "''${AC_PATH:-/sys/class/power_supply/AC/online}" 2>/dev/null || echo unknown)

        last_alert=$(cat "$STATE/last_alert" 2>/dev/null || echo 100)
        last_state=$(cat "$STATE/last_state" 2>/dev/null || echo none)

        # Journal trail: one line per status change or 10 % band.
        band=$((cap / 10))
        if [ "$status $band" != "$last_state" ]; then
          log "state=$status capacity=$cap% ac_online=$ac"
          printf '%s\n' "$status $band" > "$STATE/last_state"
        fi

        # Urgent notification on the t14's live session (D-Bus, no Wayland env
        # needed for the client itself).
        send_t14() {
          ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
              -o ConnectTimeout=6 "$T14" bash -s >/dev/null 2>&1 <<EOSSH
        export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
        export WAYLAND_DISPLAY=wayland-1
        export DISPLAY=:0
        if ! command -v notify-send >/dev/null 2>&1; then
          export PATH="$HOME/.nix-profile/bin:/run/current-system/sw/bin:$PATH"
        fi
        notify-send -u critical -a battery-guard "$1" "$2"
        EOSSH
        }

        send_tg() {
          tok=$(grep -m1 '^TELEGRAM_BOT_TOKEN=' "$SECRETS" 2>/dev/null | cut -d= -f2- | tr -d '"')
          if [ -z "$tok" ]; then
            log "telegram: no token in $SECRETS"
            return 1
          fi
          code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 2>/dev/null \
            --data-urlencode "chat_id=$CHAT" --data-urlencode "text=$1" \
            "https://api.telegram.org/bot$tok/sendMessage")
          if [ "$code" = 200 ]; then
            log "telegram: sent"
            return 0
          fi
          log "telegram: failed (http=$code)"
          return 1
        }

        alert() {
          msg="🔋 t490s on battery — $cap% (crossed $1%). Charger knocked out?"
          if send_t14 "t490s: $cap% on battery" "$msg"; then
            log "threshold $1%: notified t14"
          else
            log "threshold $1%: t14 unreachable, falling back to telegram"
            send_tg "$msg (t14 unreachable)" || log "threshold $1%: telegram also failed"
          fi
          printf '%s\n' "$1" > "$STATE/last_alert"
        }

        # `battery-guard --test` fires both delivery legs once (no state change).
        if [ "''${1:-}" = "--test" ]; then
          log "test mode: firing both legs"
          if send_t14 "battery-guard test" "🔔 battery-guard test on the t14 leg (t490s)"; then
            log "test: t14 leg OK"
          else
            log "test: t14 leg FAILED"
          fi
          if send_tg "🔔 battery-guard test — telegram leg (t490s)"; then
            log "test: telegram leg OK"
          else
            log "test: telegram leg FAILED"
          fi
          exit 0
        fi

        if [ "$status" = "Discharging" ]; then
          for t in $THRESHOLDS; do
            if [ "$cap" -le "$t" ] && [ "$last_alert" -gt "$t" ]; then
              alert "$t"
              break
            fi
          done
        elif [ "$last_alert" -lt 100 ]; then
          # Back on external power after an alert: close the loop.
          send_tg "🔌 t490s back on AC — $cap%" || true
          printf '100\n' > "$STATE/last_alert"
        fi
      '';
    in
    {
      systemd.services.battery-guard = {
        description = "Battery guard — alert (t14, then Telegram) when the pack drains on battery";
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          User = "server";
          Group = "users"; # secrets.env is root:users 0440
          StateDirectory = "battery-guard";
          StateDirectoryMode = "0750";
          ExecStart = "${script}/bin/battery-guard";
          TimeoutStartSec = "45";
        };
      };

      systemd.timers.battery-guard = {
        description = "Battery guard, every 2 min";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2min";
          OnUnitActiveSec = "2min";
          AccuracySec = "30s";
          Unit = "battery-guard.service";
        };
      };

      # Last resort, so the pack never hits 0 % mid-write again (2026-10-26:
      # the box dropped dead at 01:55 with btrfs and 10 containers live).
      # upowerd is the NixOS-native owner of "battery critical": at
      # percentageAction it issues a real logind PowerOff, i.e. systemd asks
      # docker to stop the containers and btrfs to sync — a clean shutdown,
      # not a cut. Hibernate/suspend targets are disabled on this host by
      # design, so PowerOff is the only sane action here.
      # Thresholds descend low > critical > action: 20 % warning, 10 %
      # critical, 5 % power off (~12 min of pack left after the guard's last
      # alert at 10 %). upower also keeps charge history in /var/lib/upower/,
      # which is the record that was missing last night.
      services.upower = {
        enable = true;
        percentageLow = 20;
        percentageCritical = 10;
        percentageAction = 5;
        criticalPowerAction = "PowerOff";
      };
    };

  # The receiving side: the t490s's own key may log in as pebor and nothing
  # else (restrict = no pty, no forwarding, no agent).
  flake.modules.nixos.battery-guard-target = {
    users.users.pebor.openssh.authorizedKeys.keys = [
      "restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKSvftllOdl/44hmQgUkTXnJhthiC2zdSVfSjOIKKbKl server@t490s"
    ];
  };
}
