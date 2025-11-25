{
  description = "Home Manager configuration of pebor";

  inputs = {
    # Specify the source of Home Manager and Nixpkgs.
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zen-browser.url = "github:0xc000022070/zen-browser-flake";
    helix.url = "github:helix-editor/helix";

    rose-pine-hyprcursor.url = "github:ndom91/rose-pine-hyprcursor";

    affinity-nix.url = "github:mrshmllow/affinity-nix";

    niri.url = "github:/YaLTeR/niri";
  };

  outputs = { nixpkgs, home-manager, ... } @ inputs:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      homeConfigurations = {
        "pebor@t490s" = home-manager.lib.homeManagerConfiguration {
          inherit pkgs;

          extraSpecialArgs = {inherit inputs;};

          # Specify your home configuration modules here, for example,
          # the path to your home.nix.
          modules = [
            ../hosts/t490s/home-manager
            #./home.nix
            #./fish.nix
            #./hyprland.nix
            #./packages
          ];

          # Optionally use extraSpecialArgs
          # to pass through arguments to home.nix
        };

        "pebor@t420" = home-manager.lib.homeManagerConfiguration {
          inherit pkgs;

          extraSpecialArgs = {inherit inputs;};

          # Specify your home configuration modules here, for example,
          # the path to your home.nix.
          modules = [
            ../hosts/t420/home-manager
            # ./home.nix
            # ./fish.nix
            # ./hyprland.nix
            # ./packages/terminalPrograms.nix
            # ./packages/programming.nix
            # ./packages
            # ./programs
          ];

          # Optionally use extraSpecialArgs
          # to pass through arguments to home.nix
        };
    };
  };
        
}
