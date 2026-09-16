# t14 — main laptop (ThinkPad T14 Gen 2 Intel, replaces t490s).
#
# First install: boot the NixOS ISO, then (see README "Adding a host"):
#   1. disko --mode disko hardware/t14-disko.nix   (wipes the disk)
#   2. nixos-generate-config --no-filesystems --root /mnt
#      -> copy over hardware/t14.nix
#   3. Set both stateVersions below to the ISO's release.
#   4. nixos-install --flake ~/nixos#t14 --root /mnt
{ inputs, ... }:
{
  flake.nixosConfigurations.t14 = inputs.nixpkgs.lib.nixosSystem {
    specialArgs = { inherit inputs; };
    modules = [
      inputs.self.modules.nixos.host-t14
      ../../hardware/t14.nix
    ];
  };

  flake.homeConfigurations."pebor@t14" = inputs.home-manager.lib.homeManagerConfiguration {
    pkgs = inputs.nixpkgs-hm.legacyPackages.x86_64-linux;
    extraSpecialArgs = { inherit inputs; };
    modules = [
      inputs.self.modules.homeManager.host-t14
    ];
  };

  flake.modules.nixos.host-t14 = { pkgs, ... }: {
    imports = [
      inputs.determinate.nixosModules.default
      inputs.disko.nixosModules.disko
      ../../hardware/t14-disko.nix
    ] ++ (with inputs.self.modules.nixos; [
      nix-settings
      system
      user

      hyprland
      niri
      # mango    # skipped for first install: builds from source (no binary cache)
      # cosmic   # skipped for first install: whole extra DE
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

    networking.hostName = "t14";
    # FIXME: set to the release you install with (check `nixos-version` on the ISO).
    system.stateVersion = "26.05";

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

  flake.modules.homeManager.host-t14 = {
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
      # packages-heavy # skipped for first install (big apps/dev tools)
      # llm
    ];

    # FIXME: set to the release you install with.
    home.stateVersion = "26.05";
  };
}
