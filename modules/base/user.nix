# The pebor user account. Host-specific groups get appended in host files
# (NixOS merges list options, so `extraGroups` entries add up).
{
  flake.modules.nixos.user = { pkgs, ... }: {
    programs.fish.enable = true;

    users.users.pebor = {
      isNormalUser = true;
      shell = pkgs.fish;
      description = "pebor";
      extraGroups = [
        "networkmanager"
        "wheel"
      ];
    };
  };
}
