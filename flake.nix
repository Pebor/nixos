{
  description = "Nixos config flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/*";
  };

  outputs = { self, nixpkgs, ... }@inputs: {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {

      specialArgs = {inherit inputs;};

      modules = [
        ./configuration.nix
        ./greetd.nix

        inputs.determinate.nixosModules.default
        inputs.home-manager.nixosModules.default
      ];

    };
  };
}
