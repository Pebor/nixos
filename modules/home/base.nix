# Home Manager basics shared by every host. `home.stateVersion` stays
# per-host (set in modules/hosts/<name>.nix).
{
  flake.modules.homeManager.base = {
    home.username = "pebor";
    home.homeDirectory = "/home/pebor";

    home.sessionPath = [
      "/home/pebor/.local/bin"
    ];

    home.sessionVariables = {
      EDITOR = "hx";
    };

    # Let Home Manager install and manage itself.
    programs.home-manager.enable = true;
  };
}
