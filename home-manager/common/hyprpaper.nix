{ config, pkgs, ... }:
{
  services.hyprpaper = {
    enable = true;
    settings = {
      ipc = "false";
      splash = false;
      # splash_offset = 2.0;

      preload = [ "~/nixos/resources/wallpapers/shaded_mountains.jpg" ];

      wallpaper = [
        ",~/nixos/resources/wallpapers/shaded_mountains.jpg"
      ];
    };
  };
}
