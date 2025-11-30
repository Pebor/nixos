{
  pkgs,
  inputs,
  ...
}: {
  imports = [
    ./home.nix
    ./hyprland.nix
    ./packages
  ];
    
}
