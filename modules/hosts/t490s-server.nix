# t490s-server — headless build worker + binary cache on the old t490s
# hardware. Same machine, same hardware file; the desktop config stays
# available as `t490s`.
#
# Switch (on the laptop itself):
#   cd ~/nixos && git pull
#   sudo nixos-rebuild switch --flake .#t490s-server
#
# Post-switch bootstrap — see README "t490s-server" (harmonia signing key,
# tailscale IP, client wiring).
#
# Rollback: sudo nixos-rebuild switch --flake ~/nixos#t490s
{ inputs, ... }:
{
  flake.nixosConfigurations.t490s-server = inputs.nixpkgs.lib.nixosSystem {
    specialArgs = { inherit inputs; };
    modules = [
      inputs.self.modules.nixos.host-t490s-server
      ../../hardware/t490s.nix
    ];
  };

  flake.homeConfigurations."server@t490s-server" = inputs.home-manager.lib.homeManagerConfiguration {
    pkgs = inputs.nixpkgs-hm.legacyPackages.x86_64-linux;
    extraSpecialArgs = { inherit inputs; };
    modules = [
      inputs.self.modules.homeManager.host-t490s-server
    ];
  };

  flake.modules.nixos.host-t490s-server = { pkgs, ... }: {
    imports = [
      inputs.determinate.nixosModules.default
    ] ++ (with inputs.self.modules.nixos; [
      nix-settings
      system

      ssh-server
      tailscale
      tailscale-serve
      oomd
      zram

      docker
      hermes
      hermes-secrets-sync
      battery-guard
      build-worker
      harmonia
      cache-warm
      valheim-chat-watcher
    ]);

    networking.hostName = "t490s";
    system.stateVersion = "24.11";

    # Headless console: tty1 auto-logs in as `server` so a local reboot
    # never dead-ends at a login prompt (real access is key-only ssh).
    services.getty.autologinUser = "server";
    programs.fish.enable = true;

    services.resolved.enable = true;
    services.fwupd.enable = true;

    # journald had no cap at all: the journal held 8 months / 2.1 M lines /
    # 1.4 GB and grew forever (a 30 s docker healthcheck alone contributes
    # ~1 900 lines/day). Logs are for recent debugging, so bound both size
    # and age - a noisy source now evicts old entries instead of the disk.
    services.journald.settings.Journal = {
      SystemMaxUse = "1G";
      MaxRetentionSec = "30d";
    };

    # Battery health: the pack sat at 100% permanently, which is what kills
    # Li-poly cells. ThinkPad tpacpi exposes charge thresholds via BAT0, so
    # hold it at 80% and only start charging again below 75%. udev (not a
    # boot script) because AC/firmware events re-register the battery device.
    services.udev.extraRules = ''
      ACTION=="add|change", SUBSYSTEM=="power_supply", ATTR{type}=="Battery", \
        ATTR{charge_control_start_threshold}="75", \
        ATTR{charge_control_end_threshold}="80"
    '';

    # thermald was enabled here for sustained compile loads, but it never
    # runs on this box: thinkpad_acpi registers dytc_lapmode and thermald
    # bails with "Unsupported cpu model or platform" (verified 24.10.: exited
    # 0 after 19 ms, inactive for hours). Firmware + intel_pstate already do
    # the throttling, so the unit was dead weight.

    # The server's working account (t14's key; ssh-server disables password
    # auth). base/user.nix (the pebor account) is deliberately NOT imported
    # on this host: single-account machine. Rescued files from the old
    # /home/pebor live in /home/server/pebor-rescue.
    users.users.server = {
      isNormalUser = true;
      shell = pkgs.fish;
      description = "server";
      extraGroups = [ "wheel" "docker" "networkmanager" ];
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID9MgNcjaXCtMnyhVwsb45h5cmnrLYQGTiBDY1WRXpMi pebor@nixos"
      ];
    };

    # Key-only SSH box on a private tailnet: passwordless sudo for wheel
    # keeps remote admin (nxswitch, systemctl) frictionless.
    security.sudo.wheelNeedsPassword = false;

    # Headless server: the lid does nothing and suspend simply does not
    # exist. Close it, plug it in, walk away.
    services.logind.settings.Login = {
      HandleLidSwitch = "ignore";
      HandleLidSwitchExternalPower = "ignore";
      HandleLidSwitchDocked = "ignore";
    };
    systemd.targets.sleep.enable = false;
    systemd.targets.suspend.enable = false;
    systemd.targets.hibernate.enable = false;
    systemd.targets.hybrid-sleep.enable = false;

    # Admin tooling (openssl: secret generation for service .env files etc.)
    environment.systemPackages = with pkgs; [
      openssl
      bitwarden-cli   # bw: service-vault secrets (see the vaultwarden card)
    ];
  };

  flake.modules.homeManager.host-t490s-server = { lib, ... }: {
    imports = with inputs.self.modules.homeManager; [
      nix-settings
      fish

      packages-terminal
    ];

    # home/base.nix contents inlined for the server user (base.nix itself
    # hardcodes pebor).
    home.username = "server";
    home.homeDirectory = "/home/server";
    home.sessionPath = [ "/home/server/.local/bin" ];
    home.sessionVariables.EDITOR = "hx";
    programs.home-manager.enable = true;

    home.stateVersion = "24.11";

    # The hostname is still "t490s", so nh's default attr auto-detection
    # would silently pick the OLD desktop outputs. Point the switch aliases
    # at the server outputs instead.
    programs.fish.shellAliases = {
      nxswitch = lib.mkForce "nh os switch -H t490s-server ~/nixos";
      nxedit = lib.mkForce "hx ~/nixos/modules/hosts/t490s-server.nix";
      nxeswitch = lib.mkForce "hx ~/nixos/modules/hosts/t490s-server.nix && nh os switch -H t490s-server ~/nixos";
      hmswitch = lib.mkForce "nh home switch -c server@t490s-server ~/nixos";
    };
  };
}
