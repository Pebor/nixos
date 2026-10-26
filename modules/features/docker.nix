# Docker daemon + compose plugin (t490s-server).
# The `docker` group membership for pebor comes from base/user.nix.
{
  flake.modules.nixos.docker = { pkgs, ... }: {
    virtualisation.docker = {
      enable = true;
      # Weekly cleanup of stopped containers and unused images. Safe with
      # compose-managed stacks: only resources not referenced by a running
      # container are removed.
      autoPrune = {
        enable = true;
        dates = "weekly";
      };

      # Shutdown budget for a CLEAN poweroff (battery-guard powers the box off
      # at 5 %). On daemon shutdown dockerd gives containers its own
      # --shutdown-timeout, NOT the compose stop_grace_period, so valheim's
      # 120 s world flush was really only getting the 15 s default. 90 s
      # covers a real save without stalling a routine reboot.
      extraOptions = "--shutdown-timeout=90";
    };

    # The outer bound: systemd's default 90 s stop timeout is what would
    # SIGKILL dockerd mid-save. Give it 180 s so the graceful path is actually
    # graceful. NOTE: touching this unit makes the next switch stop/start
    # docker.service, which restarts every container including the agent.
    systemd.services.docker.serviceConfig.TimeoutStopSec = "180s";

    environment.systemPackages = with pkgs; [
      docker-compose
      lazydocker
    ];
  };
}
