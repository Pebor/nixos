# t420 — older laptop, KDE Plasma + hyprland (kept for future work).
{ inputs, ... }:
{
  flake.nixosConfigurations.t420 = inputs.nixpkgs.lib.nixosSystem {
    specialArgs = { inherit inputs; };
    modules = [
      inputs.self.modules.nixos.host-t420
      ../../hardware/t420.nix
    ];
  };

  flake.homeConfigurations."pebor@t420" = inputs.home-manager.lib.homeManagerConfiguration {
    pkgs = inputs.nixpkgs-hm.legacyPackages.x86_64-linux;
    extraSpecialArgs = { inherit inputs; };
    modules = [
      inputs.self.modules.homeManager.host-t420
    ];
  };

  flake.modules.nixos.host-t420 = { pkgs, ... }: {
    imports = with inputs.self.modules.nixos; [
      nix-settings
      system
      user

      hyprland
      plasma
      desktop
    ];

    networking.hostName = "t420";
    system.stateVersion = "25.05";

    # Use latest kernel.
    boot.kernelPackages = pkgs.linuxPackages_latest;

    services.xserver.xkb = {
      layout = "us";
      variant = "";
    };

    # Automatic login.
    services.displayManager.autoLogin.enable = true;
    services.displayManager.autoLogin.user = "pebor";

    programs.firefox.enable = true;

    users.users.pebor.packages = with pkgs; [
      kdePackages.kate
    ];

    networking.firewall.allowedTCPPorts = [ 22 ];
  };

  flake.modules.homeManager.host-t420 = { pkgs, ... }: {
    imports = with inputs.self.modules.homeManager; [
      nix-settings
      base
      fish
      hyprland

      packages-terminal
      packages-programming
      packages-apps
      packages-school
      llm
    ];

    home.stateVersion = "25.05";

    # NOTE: pkgs.hyprlandPlugins.hyprscrolling no longer exists —
    # the scrolling layout was merged into Hyprland itself.
    # Enable it via settings (general.layout = "scrolling") if wanted.
    wayland.windowManager.hyprland = {
      settings.monitor = [
        ",preferred,0x0,1"
      ];
    };
  };
}
