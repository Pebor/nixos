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
    };

    environment.systemPackages = with pkgs; [
      docker-compose
      lazydocker
    ];
  };
}
