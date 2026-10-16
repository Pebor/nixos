# Cache warming (t490s-server): build client closures here so the harmonia
# cache already has them when the clients rebuild. Anything in this machine's
# store is served automatically — warming = build + keep a GC root.
#
# Input: a mirror of a client's ~/nixos working tree at ~/cache-warm/nixos,
# pushed by `cache-push` on the client (rsync, includes uncommitted changes).
# The mirror is a read-only build sandbox — never edit or git-commit from it.
#
# Manual use:  cache-warm          (or: ssh pebor@t490s cache-warm)
#              systemctl start cache-warm
# Nightly:     uncomment the timer's wantedBy below.
{
  flake.modules.nixos.cache-warm =
    { config, pkgs, lib, ... }:
    let
      cacheWarm = pkgs.writeShellApplication {
        name = "cache-warm";
        runtimeInputs = [ config.nix.package ];
        text = ''
          flake="$HOME/cache-warm/nixos"
          if [ ! -f "$flake/flake.nix" ]; then
            echo "cache-warm: no mirrored tree at $flake" >&2
            echo "run 'cache-push' on a client first" >&2
            exit 1
          fi

          # Out-links double as GC roots: the current link's closure survives
          # nix.gc, and each run replaces it so the previous one rolls out.
          nix build "$flake#nixosConfigurations.t14.config.system.build.toplevel" \
            --out-link "$HOME/cache-warm/t14-system"
          nix build "$flake#homeConfigurations.\"pebor@t14\".activationPackage" \
            --out-link "$HOME/cache-warm/t14-home"

          echo "cache-warm: done; closures rooted under $HOME/cache-warm/"
        '';
      };
    in
    {
      environment.systemPackages = [ cacheWarm ];

      # Mirror staging dir (created before the first cache-push).
      systemd.tmpfiles.rules = [
        "d /home/pebor/cache-warm 0755 pebor users -"
      ];

      systemd.services.cache-warm = {
        description = "Build client closures for the harmonia binary cache";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          User = "pebor";
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
