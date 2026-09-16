# t490s — main laptop.
{ inputs, ... }:
{
  flake.nixosConfigurations.t490s = inputs.nixpkgs.lib.nixosSystem {
    specialArgs = { inherit inputs; };
    modules = [
      inputs.self.modules.nixos.host-t490s
      ../../hardware/t490s.nix
    ];
  };

  flake.homeConfigurations."pebor@t490s" = inputs.home-manager.lib.homeManagerConfiguration {
    pkgs = inputs.nixpkgs-hm.legacyPackages.x86_64-linux;
    extraSpecialArgs = { inherit inputs; };
    modules = [
      inputs.self.modules.homeManager.host-t490s
    ];
  };

  flake.modules.nixos.host-t490s = { pkgs, ... }: {
    imports = [
      inputs.determinate.nixosModules.default
    ] ++ (with inputs.self.modules.nixos; [
      nix-settings
      system
      user

      hyprland
      niri
      mango
      cosmic
      greetd
      stylix

      gaming
      desktop
      laptop
      plymouth
      tailscale
      nix-ld
      oomd
    ]);

    networking.hostName = "t490s";
    system.stateVersion = "24.11";

    services.resolved.enable = true;
    services.fwupd.enable = true;

    hardware.opentabletdriver.enable = true;

    # Controller (xpad) + vial keyboard udev rules.
    services.udev.extraRules = ''
      ACTION=="add", ATTRS{idVendor}=="2dc8", ATTRS{idProduct}=="301c", MODE="0666", \
      RUN+="/sbin/modprobe xpad", \
      RUN+="/bin/sh -c 'echo 2dc8 301c > /sys/bus/usb/drivers/xpad/new_id'"
      KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{serial}=="*vial:f64c2b3c*", MODE="0660", GROUP="users", TAG+="uaccess", TAG+="udev-acl"
    '';

    users.users.pebor.extraGroups = [ "adbusers" "kvm" ];

    # Czech keymaps (base/system.nix does not set these).
    services.xserver.xkb = {
      layout = "cz";
      variant = "";
    };
    console.keyMap = "cz-lat2";

    environment.systemPackages = with pkgs; [
      android-tools
      android-studio

      inputs.noctalia.packages.${pkgs.stdenv.hostPlatform.system}.default
    ];
  };

  flake.modules.homeManager.host-t490s = {
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
      # llm
    ];

    home.stateVersion = "24.11";

    # Host-specific hyprland additions (rmenu binds removed with rmenu).
    wayland.windowManager.hyprland.settings.bind = [
      "$mainMod, o, exec, ~/.config/hypr/otter.sh"
    ];
  };
}
