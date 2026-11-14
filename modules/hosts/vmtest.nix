# vmtest — throwaway Hyprland box for GUI testing.
#
# ONE control channel: ssh -i ~/.ssh/vmtest -p 2222 pebor@127.0.0.1
#   boot:   systemctl --user start vmtest
#   run:    ssh ... 'nohup launchpad &'
#   shot:   ssh ... 'grim /tmp/s.png' && scp ...
# No 9p, no serial sockets, no guest-side services.
{ inputs, ... }:
let
  sys = "x86_64-linux";
  wallpaper = ../../resources/wallpapers/shaded_mountains.jpg;
in
{
  flake.nixosConfigurations.vmtest = inputs.nixpkgs.lib.nixosSystem {
    specialArgs = { inherit inputs; };
    modules = [ inputs.self.modules.nixos.host-vmtest ];
  };

  flake.modules.nixos.host-vmtest = { pkgs, lib, ... }: {
    nixpkgs.hostPlatform = sys;
    system.stateVersion = "26.05";
    stylix.autoEnable = false;

    imports =
      (with inputs.self.modules.nixos; [ nix-settings system hyprland stylix bootvine ])
      ++ [ inputs.home-manager.nixosModules.home-manager ];

    users.users.pebor = {
      isNormalUser = true;
      uid = 1000;
      extraGroups = [ "wheel" "video" "input" "render" ];
      password = "test";
      shell = pkgs.bash;
      openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILzWOt2jXZyP5rp/T4oacnRAJHWYMpcg+LQKjaNxIj8B vmtest" ];
    };
    security.sudo.wheelNeedsPassword = false;

    services.openssh = {
      enable = true;
      settings.PasswordAuthentication = false;
      settings.PermitRootLogin = "no";
    };

    services.getty.autologinUser = "pebor";
    environment.loginShellInit = ''
      if [ "$(tty)" = "/dev/tty1" ] && [ -z "$WAYLAND_DISPLAY" ]; then
        export LIBGL_ALWAYS_SOFTWARE=1
        exec Hyprland > /tmp/hyprland.log 2>&1
      fi
    '';

    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      extraSpecialArgs = { inherit inputs; };
      users.pebor = {
        home.username = "pebor";
        home.homeDirectory = "/home/pebor";
        home.stateVersion = "26.05";
        imports = [
          inputs.self.modules.homeManager.hyprland
          inputs.self.modules.homeManager.native-apps
        ];
        home.packages = [ inputs.noctalia.packages.${sys}.default ];
        # noctalia paints its own wallpaper layer — point it at the same image
        xdg.configFile."noctalia/config.toml".text = ''
          [wallpaper]
          enabled = true
          fill_mode = "crop"

          [wallpaper.default]
          path = "/home/pebor/nixos/resources/wallpapers/shaded_mountains.jpg"
        '';
      };
    };

    # home-manager activation does not run in the VM, so place these directly
    system.activationScripts.vmtestFiles = {
      text = ''
        install -d -m 0755 -o pebor -g users /home/pebor/nixos/resources/wallpapers /home/pebor/.config/noctalia
        install -m 0644 -o pebor -g users ${wallpaper} /home/pebor/nixos/resources/wallpapers/shaded_mountains.jpg
        cat > /home/pebor/.config/noctalia/config.toml <<'CFG'
        [wallpaper]
        enabled = true
        fill_mode = "crop"

        [wallpaper.default]
        path = "/home/pebor/nixos/resources/wallpapers/shaded_mountains.jpg"

        [shell]
        setupWizardEnabled = false
        CFG
        install -d -m 0755 -o pebor -g users /home/pebor/.local/state/noctalia
        touch /home/pebor/.local/state/noctalia/.setup-complete
        chown pebor:users /home/pebor/.local/state/noctalia/.setup-complete
        chown pebor:users /home/pebor/.config/noctalia/config.toml
      '';
    };

    hardware.graphics.enable = true;

    # run a binary copied over ssh: vm-app launchpad -q ze
    environment.systemPackages = with pkgs; [
      grim imagemagick curl jq foot hyprpaper
      (writeShellScriptBin "vm-app" ''
        export LD_LIBRARY_PATH="${lib.makeLibraryPath [
          libx11 libxcursor libxrandr libxi libxcb libxkbcommon
          mesa vulkan-loader wayland fontconfig freetype
          glib gtk3 pango cairo gdk-pixbuf harfbuzz libepoxy
          webkitgtk_4_1 libsoup_3 glib-networking gtk-layer-shell
        ]}"
        export GIO_EXTRA_MODULES="${glib-networking}/lib/gio/modules"
        export XDG_RUNTIME_DIR=/run/user/1000
        export WAYLAND_DISPLAY="''${WAYLAND_DISPLAY:-wayland-1}"
        name="$1"; shift
        exec "$HOME/apps/$name" "$@"
      '')
    ];

    virtualisation.vmVariant.virtualisation = {
      memorySize = 4096;
      cores = 2;
      diskSize = 4096;
      graphics = false;
      forwardPorts = [
        { from = "host"; host.port = 2222; guest.port = 22; }
      ];
    };
  };
}
