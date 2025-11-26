{
  pkgs,
  inputs,
  ...
}: {
  imports = [
    ./home.nix
    ./packages
  ];
    
}
