{
  description = "Nixos config flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/*";

    logseq-nightly = {
      url = "github:Bad3r/nix-logseq-git-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    mangowc = {
      url = "github:mangowm/mango";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # shko = {
    #   url = "git+https://www.codeberg.org/polygonalbones/shko-flake";
    #   inputs.nixpkgs.follows = "nixpkgs";
    # };

    stylix = {
      url = "github:nix-community/stylix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    
    noctalia = {
      url = "github:noctalia-dev/noctalia-shell";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.noctalia-qs.follows = "noctalia-qs";
    };

    noctalia-qs = {
      url = "github:noctalia-dev/noctalia-qs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
          inputs.stylix.nixosModules.default
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
