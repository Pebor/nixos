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
    nixosConfigurations = {
      
      t490s = nixpkgs.lib.nixosSystem {
        specialArgs = {inherit inputs;};

        modules = [
          ./hosts/t490s
          ./greetd.nix

          inputs.determinate.nixosModules.default
          inputs.home-manager.nixosModules.default
        ];
      };

      t420 = nixpkgs.lib.nixosSystem {
        specialArgs = {inherit inputs;};

        modules = [
          ./hosts/t420
          # ./greetd.nix

          # inputs.determinate.nixosModules.default
          inputs.home-manager.nixosModules.default
        ];
      };

      t420-server = nixpkgs.lib.nixosSystem {
        specialArgs = {inherit inputs;};

        modules = [
          ./hosts/t420-server
          # ./greetd.nix

          # inputs.determinate.nixosModules.default
          inputs.home-manager.nixosModules.default
        ];
      };

    };
  };
}
