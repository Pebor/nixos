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

  flake.modules.nixos.host-t14 = { pkgs, lib, ... }: {
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
      # laptop #trying something different rn
      plymouth
      tailscale
      build-client
      nix-ld
      oomd
      zram

      ssh-server
      hermes-access
    ]);

    boot.kernelParams = [
      "i8042.nopnp=1"
      "i8042.nomux=1"
      "i8042.reset=1"
      "loglevel=1"
      "systemd.show_status=auto"
      "quiet"
      "rd.udev.log_level=1"
      "i915.enable_psr=1"
      "i915.enable_fbc=1"
    ];

    # boot.kernel.sysctl = {
    #   "kernel.printk" = "1 4 1 7";
    # };

    boot.extraModprobeConfig = ''
      options thinkpad_acpi fan_control=1 i2c_i801 disable_features=0x10
    '';

    # Release the fingerprint device before suspend so an in-progress PAM
    # verification cannot survive the device reset during S3 resume.
    powerManagement.powerDownCommands = ''
      systemctl stop fprintd.service || true
    '';
    powerManagement.resumeCommands = ''
      systemctl restart fprintd.service
    '';

    # Suspend on lid close even when the charger or an external display is
    # connected. Use systemd-inhibit when the closed-lid desktop is desired.
    services.logind.settings.Login = {
      HandleLidSwitchExternalPower = "suspend";
      HandleLidSwitchDocked = "suspend";
    };

    programs.umbriel.enable = true;

    services.thinkfan = {
      enable = true;
      smartSupport = true; 
      # Formát: [ úroveň_rychlosti  teplota_pro_snížení  teplota_pro_zvýšení ]
      # Úrovně pro ThinkPad jsou 0 (ticho) až 7 (max). Level 7 je nejvyšší
      # bezpečná úroveň; "full-speed"/"disengaged" jsou mimo specifikaci.
      levels = [
        [ 0  0  55 ]   # Úplné ticho. Větrák stojí, dokud CPU nepřesáhne 55 °C
        [ 1  50 62 ]   # Nejnižší rychlost (téměř neslyšná) mezi 55 °C a 62 °C
        [ 2  57 67 ]   # Mírné zvýšení otáček při běžné střední zátěži
        [ 3  63 72 ]   # Vyšší otáčky pro delší kompilaci/práci
        [ 6  68 80 ]   # Výkonný režim
        [ 7  75 32767 ] # Maximální chlazení (nejvyšší bezpečná úroveň) — drží se i nad 85 °C
      ];
    };

    services.auto-cpufreq.enable = false;
    powerManagement.powertop.enable = true;
    services.power-profiles-daemon.enable = false;
    services.upower.enable = true;
    services.tlp = {
      enable = true;
      settings = {
        # Chování na nabíječce (AC) - plný výkon
        CPU_SCALING_GOVERNOR_ON_AC = "performance";
        CPU_ENERGY_PERF_POLICY_ON_AC = "performance";
        CPU_BOOST_ON_AC = 1;

        # Chování na baterii (BAT) - maximální úspora
        CPU_SCALING_GOVERNOR_ON_BAT = "powersave";
        CPU_ENERGY_PERF_POLICY_ON_BAT = "power";
        CPU_BOOST_ON_BAT = 0; # Totální zákaz Turbo Boostu
    
        # Agresivní uspávání PCIe linek a Wi-Fi
        PCIE_ASPM_ON_BAT = "powersupersave";
        WIFI_PWR_ON_BAT = "on";
      };
    };


    # T14 Gen 2 prints harmless but constant ACPI (AE_NOT_FOUND) and
    # "thermal_zone: failed to read out thermal zone" errors at KERN_ERR
    # level, which "quiet" still shows — flooding the console/greetd.
    # Drop console loglevel below KERN_ERR; journalctl keeps everything.
    boot.consoleLogLevel = 3;

    services.resolved.enable = true;
    services.fwupd.enable = true;

    services.fprintd.enable = true;

    services.gnome.gnome-keyring.enable = true;
    security.pam.services.login.enableGnomeKeyring = true;
    security.pam.services.greetd.enableGnomeKeyring = true;
    programs.dconf.enable = true;
    security.polkit.enable = true;
    programs.seahorse.enable = true;

    # usb in files
    services.udisks2.enable = true;
    services.gvfs.enable = true; # Often required by file managers to interact with udisks2

    hardware.opentabletdriver.enable = false;

    networking.hostName = "t14";
    system.stateVersion = "26.05";

    # Controller (xpad) + vial keyboard udev rules.
    services.udev.extraRules = ''
      ACTION=="add", ATTRS{idVendor}=="2dc8", ATTRS{idProduct}=="301c", MODE="0666", \
      RUN+="/sbin/modprobe xpad", \
      RUN+="/bin/sh -c 'echo 2dc8 301c > /sys/bus/usb/drivers/xpad/new_id'"
      KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{serial}=="*vial:f64c2b3c*", MODE="0660", GROUP="users", TAG+="uaccess", TAG+="udev-acl"
    '';

    users.users.pebor.extraGroups = [ "adbusers" "kvm" "docker" ];

    # Czech keymaps (base/system.nix does not set these).
    services.xserver.xkb = {
      layout = "cz";
      variant = "";
    };
    console.keyMap = "cz-lat2";

    programs.hyprlock.enable = lib.mkForce true; # needed for the hyprlock PAM service

    environment.systemPackages = with pkgs; [
      android-tools
      android-studio

      inputs.noctalia.packages.${pkgs.stdenv.hostPlatform.system}.default
    ];
  };

  flake.modules.homeManager.host-t14 = {pkgs, lib, ...}: {
    imports = with inputs.self.modules.homeManager; [
      nix-settings
      base
      fish
      hyprland
      activity-monitor
      stylix

      packages-terminal
      hermes-client
      packages-programming
      packages-apps
      packages-school
      # llm
    ];

    home.stateVersion = "26.05";

    services.hyprpaper.enable = lib.mkForce false;
    
    wayland.windowManager.hyprland.settings = {
        "exec-once" = lib.mkForce [
          # "waybar"
          "noctalia"
          # "dunst"
          "dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP"
        ];

        device = [
          {
            name = "tpps/2-elan-trackpoint";
            sensitivity = -0.4;
          }
        ];

        workspace = [
          "1, monitor:eDP-1, default:true"
          "2, monitor:eDP-1"
          "3, monitor:eDP-1"
          "4, monitor:eDP-1"
          "5, monitor:eDP-1"
          "6, monitor:HDMI-A-1, default:true"
          "7, monitor:HDMI-A-1"
          "8, monitor:HDMI-A-1"
          "9, monitor:HDMI-A-1"
          "10, monitor:HDMI-A-1"
        ];

        bind = [
          # Move the entire current workspace to the next monitor
          "$mainMod SHIFT, O, movecurrentworkspacetomonitor, +1"
          
          # Swap the active workspaces of the current and next monitor
          "$mainMod CTRL, O, swapactiveworkspaces, current +1"
          
          # Quickly move focus to the next/previous monitor without moving windows
          "$mainMod, TAB, focusmonitor, +1"
          "$mainMod SHIFT, TAB, focusmonitor, -1"
          
          # Optional: Move the active window to the next monitor silently
          "$mainMod ALT, O, movewindow, mon:+1"
          # Cycle through windows forward
          "ALT, Tab, focuscurrentorlast,"
          "ALT, Tab, bringactivetotop,"
          
          # Cycle through windows backward
          "ALT SHIFT, Tab, focuscurrentorlast, prev"
          "ALT SHIFT, Tab, bringactivetotop,"
        ];
    };
  };
}
