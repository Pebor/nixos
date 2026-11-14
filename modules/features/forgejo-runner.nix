# forgejo-runner — CI for git.pebor.me, host mode, on the box that builds.
#
# The runner executes jobs directly on this machine (label `t490s:host`), which
# is what makes "call the agent from a pipeline step" a plain command: `hermes`
# is on PATH, ~/.ssh holds the VPS key, node/pnpm are real. No job container,
# no image to rebuild — and workflow code therefore runs as `server` with its
# sudo, so only private repos may use this runner (no fork PRs).
#
# State (`/var/lib/forgejo-runner`): `config.yaml` + `.runner` (registration,
# created once by `forgejo-runner register`, never by nix — the token is a
# secret). The unit refuses to start until `.runner` exists.
{ ... }:
{
  flake.modules.nixos.forgejo-runner = { pkgs, ... }: {
    environment.systemPackages = [ pkgs.forgejo-runner ];

    systemd.services.forgejo-runner = {
      description = "Forgejo Actions runner (host mode, label t490s:host)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # Steps inherit this PATH — pnpm/node/git are deliberately explicit: the
      # system profile has neither pnpm nor node, so a workflow's `pnpm build`
      # would die "command not found" halfway through a deploy.
      path = with pkgs; [
        bash
        coreutils
        git
        openssh
        rsync
        curl
        jq
        nodejs_22
        pnpm
        # the system profile itself: `hermes` lives in it and a workflow step
        # calling the agent needs it on PATH (steps inherit this daemon's PATH).
        "/run/current-system/sw"
      ];
      environment = {
        HOME = "/home/server";
      };
      # [Unit] section, not [Service]: a unit cannot run before it is registered,
      # and `forgejo-runner register` is a one-off with a secret token.
      unitConfig.ConditionPathExists = "/var/lib/forgejo-runner/.runner";
      serviceConfig = {
        Type = "simple";
        User = "server";
        Group = "users";
        WorkingDirectory = "/var/lib/forgejo-runner";
        StateDirectory = "forgejo-runner";
        StateDirectoryMode = "0755";
        ExecStart = "${pkgs.forgejo-runner}/bin/forgejo-runner daemon --config /var/lib/forgejo-runner/config.yaml";
        Restart = "always";
        RestartSec = 10;
      };
    };
  };
}
