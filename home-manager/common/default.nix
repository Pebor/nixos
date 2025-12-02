{
  pkgs,
  inputs,
  ...
}: {

  imports = [
    ./fish.nix
    ./hyprland.nix
    ./hypridle.nix
    ./hyprlock.nix
    ./hyprpaper.nix
  ];
    
}
