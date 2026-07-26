{ config, pkgs, ... }:
{
  services.hyprpaper = {
    enable = true;
    settings = {
      ipc = false;
      splash = false;

      wallpaper = [
        {
          monitor="";
          path = "~/nixos/resources/wallpapers/shaded_mountains.jpg";
        }
      ];
      # splash_offset = 2.0;

      # preload = [ "~/nixos/resources/wallpapers/shaded_mountains.jpg" ];

    };
  };
}
