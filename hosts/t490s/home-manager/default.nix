{
  pkgs,
  inputs,
  ...
}: {
  imports = [
    ./home.nix
    ./packages
    ./hyprland.nix
  ];
    
}
