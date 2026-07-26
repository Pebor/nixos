# t420-server — headless server (kept for future work).
# NOTE: its Home Manager output is newly wired up — it existed only as
# dead files before. Server-sensible HM: terminal + programming + llm.
{ inputs, ... }:
{
  flake.nixosConfigurations.t420-server = inputs.nixpkgs.lib.nixosSystem {
    specialArgs = { inherit inputs; };
    modules = [
      inputs.self.modules.nixos.host-t420-server
      ../../hardware/t420-server.nix
    ];
  };

  flake.homeConfigurations."pebor@t420-server" = inputs.home-manager.lib.homeManagerConfiguration {
    pkgs = inputs.nixpkgs-hm.legacyPackages.x86_64-linux;
    extraSpecialArgs = { inherit inputs; };
    modules = [
      inputs.self.modules.homeManager.host-t420-server
    ];
  };

  flake.modules.nixos.host-t420-server = { pkgs, ... }: {
    imports = with inputs.self.modules.nixos; [
      nix-settings
      system
      user

      ssh-server
    ];

    networking.hostName = "t420-server";
    system.stateVersion = "25.05";

    # Use latest kernel.
    boot.kernelPackages = pkgs.linuxPackages_latest;

    services.xserver.xkb = {
      layout = "us";
      variant = "";
    };

    services.printing.enable = true;

    # Server behavior: never suspend, ignore the lid.
    services.logind.lidSwitchExternalPower = "ignore";
    powerManagement.enable = false;

    environment.systemPackages = with pkgs; [
      helix
    ];
  };

  flake.modules.homeManager.host-t420-server = {
    imports = with inputs.self.modules.homeManager; [
      nix-settings
      base
      fish

      packages-terminal
      packages-programming
      llm
    ];

    home.stateVersion = "25.05";
  };
}
