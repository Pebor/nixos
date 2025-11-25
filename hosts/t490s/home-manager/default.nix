{
  pkgs,
  inputs,
  ...
}: {
  imports = [
    ./home.nix
    ./fish.nix
    ./hyprland.nix
    ./packages
  ];
    
}
