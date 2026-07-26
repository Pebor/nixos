# Gaming: steam, gamemode, gamescope (each program module also adds its package).
{
  flake.modules.nixos.gaming = {
    programs.steam.enable = true;
    programs.gamemode.enable = true;
    programs.gamescope.enable = true;
  };
}
