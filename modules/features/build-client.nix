# Client side of distributed builds + binary cache (t14, desktop).
#
# Offloads nix builds to t490s-server over tailscale and substitutes from its
# harmonia cache. The server is preferred (speedFactor 2) but local cores
# stay as fallback — for hard offload set `nix.settings.max-jobs = 0` in the
# host file.
#
# Two values below are filled in after the server is switched:
#   builderIp    — the server's tailscale IP (tailscale status)
#   cachePubKey  — /var/lib/harmonia/cache-key.pub on the server
{
  flake.modules.nixos.build-client =
    { pkgs, ... }:
    let
      # The server's tailscale IP (tailscale IPs are stable per machine).
      builderIp = "100.103.136.50";
      cachePubKey = "t490s-cache-1:myatSvZj3oiDANq2cOz8GhEl37gvQjdtA2LJYvB9OHI=";
    in
    {
      nix.distributedBuilds = true;
      nix.buildMachines = [
        {
          hostName = builderIp;
          sshUser = "nixbuild";
          sshKey = "/root/.ssh/nixbuild_ed25519";
          protocol = "ssh-ng";
          system = "x86_64-linux";
          maxJobs = 4;
          speedFactor = 2;
          supportedFeatures = [
            "nixos-test"
            "benchmark"
            "big-parallel"
            "kvm"
          ];
        }
      ];
      nix.settings = {
        # Let the server substitute from upstream caches instead of the
        # client uploading build inputs.
        builders-use-substitutes = true;
        substituters = [ "http://${builderIp}:5000" ];
        trusted-public-keys = [ cachePubKey ];
      };

      # cache-push: mirror ~/nixos to the server for cache warming.
      #   cache-push         stage the tree; the night timer picks it up
      #   cache-push --now   stage and build immediately
      # rsync --delete keeps the mirror exact (stale files removed); the
      # .git dir never crosses. The mirror is a read-only build sandbox on
      # the server — source of truth stays here.
      environment.systemPackages = [
        (pkgs.writeShellApplication {
          name = "cache-push";
          runtimeInputs = with pkgs; [ rsync openssh ];
          text = ''
            set -euo pipefail
            rsync -a --delete --exclude=.git "$HOME/nixos/" \
              server@t490s:cache-warm/nixos/
            echo "nixos tree mirrored to t490s:~/cache-warm/nixos"
            if [ "''${1:-}" = "--now" ]; then
              ssh server@t490s cache-warm
            else
              echo "queued for the next cache-warm run (or: cache-push --now)"
            fi
          '';
        })
      ];
    };
}
