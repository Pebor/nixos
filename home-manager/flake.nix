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
    helium = {
      url = "github:schembriaiden/helium-browser-nix-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    helix.url = "github:helix-editor/helix";

    rose-pine-hyprcursor.url = "github:ndom91/rose-pine-hyprcursor";

    affinity-nix.url = "github:mrshmllow/affinity-nix";

    niri.url = "github:/YaLTeR/niri";
    dms = {
      url = "github:AvengeMedia/DankMaterialShell/stable";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    otter-launcher.url = "github:/kuokuo123/otter-launcher";

    stylix = {
      url = "github:nix-community/stylix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, home-manager, ... }@inputs:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {

      homeConfigurations = {
        "pebor@t490s" = home-manager.lib.homeManagerConfiguration {
          inherit pkgs;

          extraSpecialArgs = { inherit inputs; };

          # Specify your home configuration modules here, for example,
          # the path to your home.nix.
          modules = [
            inputs.stylix.homeModules.stylix
            inputs.dms.homeModules.dank-material-shell
            {
              programs.dank-material-shell = {
                enable = false;

                enableSystemMonitoring = true;
                enableDynamicTheming = true;
                # enableCalendarEvents = true;
                enableClipboardPaste = true;
              };
            }
            ./common
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

          extraSpecialArgs = { inherit inputs; };

          # Specify your home configuration modules here, for example,
          # the path to your home.nix.
          modules = [
            ./common
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
