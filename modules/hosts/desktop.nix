# desktop — new desktop PC (migration target).
#
# Before the first switch on the real machine:
#   1. Run `nixos-generate-config` there and copy its
#      hardware-configuration.nix over hardware/desktop.nix.
#   2. Set the correct `system.stateVersion` / `home.stateVersion`
#      to the release you install with.
#   3. Adjust the hyprland monitor line below for your displays.
#   4. If the GPU needs special handling (NVIDIA/AMD), add a feature
#      module under modules/features/ and import it here.
{ inputs, ... }:
{
  flake.nixosConfigurations.desktop = inputs.nixpkgs.lib.nixosSystem {
    specialArgs = { inherit inputs; };
    modules = [
      inputs.self.modules.nixos.host-desktop
      ../../hardware/desktop.nix
    ];
  };

  flake.homeConfigurations."pebor@desktop" = inputs.home-manager.lib.homeManagerConfiguration {
    pkgs = inputs.nixpkgs-hm.legacyPackages.x86_64-linux;
    extraSpecialArgs = { inherit inputs; };
    modules = [
      inputs.self.modules.homeManager.host-desktop
    ];
  };

  flake.modules.nixos.host-desktop = { pkgs, ... }: {
    imports = [
      inputs.determinate.nixosModules.default
    ] ++ (with inputs.self.modules.nixos; [
      nix-settings
      system
      user

      hyprland
      niri
      greetd
      stylix

      gaming
      desktop
      tailscale
      nix-ld
      oomd
    ]);

    networking.hostName = "desktop";
    # FIXME: set to the release you install with.
    system.stateVersion = "25.05";

    services.resolved.enable = true;
    services.fwupd.enable = true;

    # Czech keymaps (base/system.nix does not set these).
    services.xserver.xkb = {
      layout = "cz";
      variant = "";
    };
    console.keyMap = "cz-lat2";
  };

  flake.modules.homeManager.host-desktop = {
    imports = with inputs.self.modules.homeManager; [
      nix-settings
      base
      fish
      hyprland
      stylix

      packages-terminal
      packages-programming
      packages-apps
      packages-school
      packages-heavy
      llm
    ];

    # FIXME: set to the release you install with.
    home.stateVersion = "25.05";

    # FIXME: adjust for your monitors.
    wayland.windowManager.hyprland.settings.monitor = [
      ",preferred,0x0,1"
    ];
  };
}
