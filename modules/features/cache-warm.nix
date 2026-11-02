# Cache warming (t490s-server): build client closures here so the harmonia
# cache already has them when the clients rebuild. Anything in this machine's
# store is served automatically — warming = build + keep a GC root.
#
# Input: a mirror of a client's ~/nixos working tree at ~/cache-warm/nixos,
# pushed by `cache-push` on the client (rsync, includes uncommitted changes).
# The mirror is a read-only build sandbox — never edit or git-commit from it.
#
# Manual use:  cache-warm          (or: ssh pebor@t490s cache-warm)
#              cache-warm --rom    (force the rom tree; cache-push uses this)
#              systemctl start cache-warm
# Nightly:     uncomment the timer's wantedBy below.
{
  flake.modules.nixos.cache-warm =
    { config, pkgs, lib, inputs, ... }:
    let
      rom = inputs.rom.packages.${pkgs.stdenv.hostPlatform.system}.default;
      cacheWarm = pkgs.writeShellApplication {
        name = "cache-warm";
        runtimeInputs = [ config.nix.package rom pkgs.coreutils ];
        text = ''
          flake="$HOME/cache-warm/nixos"
          if [ ! -f "$flake/flake.nix" ]; then
            echo "cache-warm: no mirrored tree at $flake" >&2
            echo "run 'cache-push' on a client first" >&2
            exit 1
          fi

          # `--rom` forces the TUI (cache-push uses it over `ssh -t`); without
          # a terminal (the systemd unit) fall back to plain nix output.
          mode="plain"
          if [ "''${1:-}" = "--rom" ]; then mode="rom"; fi

          build() {
            if [ "$mode" = "rom" ] || [ -t 1 ]; then
              rom --icons unicode --format tree --legend table build "$1" -- --out-link "$2"
            else
              nix build "$1" --out-link "$2"
            fi
          }

          diff_closure() {
            old="$1"; new="$2"; label="$3"
            if [ -n "$old" ] && [ "$old" != "$new" ]; then
              echo
              echo "== $label: změny verzí =="
              nix store diff-closures "$old" "$new" || true
            fi
          }

          # Out-links double as GC roots: the current link's closure survives
          # nix.gc, and each run replaces it so the previous one rolls out.
          old_system=$(readlink "$HOME/cache-warm/t14-system" 2>/dev/null || true)
          build "$flake#nixosConfigurations.t14.config.system.build.toplevel" \
            "$HOME/cache-warm/t14-system"
          new_system=$(readlink "$HOME/cache-warm/t14-system" 2>/dev/null || true)
          diff_closure "$old_system" "$new_system" "t14 system"

          old_home=$(readlink "$HOME/cache-warm/t14-home" 2>/dev/null || true)
          build "$flake#homeConfigurations.\"pebor@t14\".activationPackage" \
            "$HOME/cache-warm/t14-home"
          new_home=$(readlink "$HOME/cache-warm/t14-home" 2>/dev/null || true)
          diff_closure "$old_home" "$new_home" "t14 home"

          echo "cache-warm: done; closures rooted under $HOME/cache-warm/"
        '';
      };
    in
    {
      environment.systemPackages = [ cacheWarm rom ];

      # Mirror staging dir (created before the first cache-push).
      systemd.tmpfiles.rules = [
        "d /home/server/cache-warm 0755 server users -"
      ];

      systemd.services.cache-warm = {
        description = "Build client closures for the harmonia binary cache";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          User = "server";
          Group = "users";
          ExecStart = lib.getExe cacheWarm;
          # Builds can take far longer than the default 90s start timeout.
          TimeoutStartSec = "infinity";
        };
      };

      systemd.timers.cache-warm = {
        description = "Nightly cache warming for build clients";
        timerConfig = {
          OnCalendar = "03:30";
          Persistent = true;
        };
        # Enable after manual testing: run `systemctl start cache-warm` once,
        # then uncomment:
        # wantedBy = [ "timers.target" ];
      };
    };
}
