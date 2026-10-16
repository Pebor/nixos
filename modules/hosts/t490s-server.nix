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
      user

      ssh-server
      tailscale
      oomd

      docker
      hermes
      build-worker
      harmonia
      cache-warm
    ]);

    networking.hostName = "t490s";
    system.stateVersion = "24.11";

    services.resolved.enable = true;
    services.fwupd.enable = true;
    # Sustained compile loads with the lid closed: let Intel's thermal
    # daemon manage the CPU.
    services.thermald.enable = true;

    # The server's working account (t14's key; ssh-server disables password
    # auth). pebor stays defined via base/user.nix only as the owner of the
    # archived pre-server files in /home/pebor — no remote access.
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
