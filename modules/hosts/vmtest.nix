# vmtest — Pebor's throwaway Hyprland test box on the t490s.
#
# Small on purpose: 2 GB RAM, 2 cores, sparse 4 GB disk. Self-contained: the app
# binaries are baked into the image, no shared folders, no home-manager (its
# activation service does not work in this VM), so the session is described here
# in plain nix. The agent drives it through a QEMU monitor socket (`screendump`)
# and a serial socket (`socat`), and never touches the real laptop.
{ inputs, ... }:
let
  sys = "x86_64-linux";
  wallpaper = ../../resources/wallpapers/shaded_mountains.jpg;

  # same LD_LIBRARY_PATH recipe the laptop's native-apps module uses
  mkApp = pkgs: name: bin: pkgs.writeShellScriptBin name ''
    export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath (with pkgs; [
      libx11 libxcursor libxrandr libxi libxcb libxkbcommon
      mesa vulkan-loader wayland fontconfig freetype
      glib gtk3 pango cairo gdk-pixbuf harfbuzz libepoxy
      webkitgtk_4_1 libsoup_3 glib-networking gtk-layer-shell
    ])}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export GIO_EXTRA_MODULES="${pkgs.glib-networking}/lib/gio/modules"
    exec ${pkgs.runCommand "apps-${name}" { } ''
      mkdir -p $out/bin
      cp ${/home/server/vmtest-bin/launchpad} $out/bin/launchpad
      cp ${/home/server/vmtest-bin/agent-watch} $out/bin/agent-watch
      cp ${/home/server/vmtest-bin/webtest} $out/bin/webtest
      chmod 755 $out/bin/*
    ''}/bin/${bin} "$@"
  '';

  hyprlandConf = pkgs: pkgs.writeText "vmtest-hyprland.conf" ''
    monitor=,preferred,auto,1
    exec-once = ${pkgs.hyprpaper}/bin/hyprpaper
    exec-once = ${inputs.noctalia.packages.${sys}.default}/bin/noctalia
    $mainMod = SUPER
    bind = $mainMod, RETURN, exec, ${pkgs.foot}/bin/foot
    bind = $mainMod, Q, killactive
    bind = $mainMod, R, exec, vm-launchpad
    bind = $mainMod SHIFT, W, exec, vm-watch
    bind = $mainMod SHIFT, C, exec, vm-chat
    bind = $mainMod, F, fullscreen, 0
    input { kb_layout = cz,cz
            kb_variant = coder,
            kb_options = grp:alt_ctrl_toggle
            follow_mouse = 1 }
    general { gaps_in = 5
              gaps_out = 10
              col.active_border = 0xffA1BDCE
              col.inactive_border = rgba(595959aa) }
    decoration { rounding = 8 }
  '';

  hyprpaperConf = pkgs: pkgs.writeText "vmtest-hyprpaper.conf" ''
    preload = ${wallpaper}
    wallpaper = ,${wallpaper}
  '';
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

    imports = (with inputs.self.modules.nixos; [ nix-settings system hyprland stylix ]);

    users.users.pebor = {
      isNormalUser = true;
      uid = 1000;
      extraGroups = [ "wheel" "video" "input" "render" ];
      password = "test";
      shell = pkgs.bash;
    };
    security.sudo.wheelNeedsPassword = false;
    services.getty.autologinUser = "pebor";
    systemd.services."serial-getty@ttyS1".enable = true;

    environment.loginShellInit = ''
      if [ "$(tty)" = "/dev/tty1" ] && [ -z "$WAYLAND_DISPLAY" ]; then
        export LIBGL_ALWAYS_SOFTWARE=1
        exec Hyprland > /tmp/hyprland.log 2>&1
      fi
    '';

    environment.systemPackages = with pkgs; [
      (mkApp pkgs "vm-launchpad" "launchpad")
      (mkApp pkgs "vm-watch" "agent-watch")
      (mkApp pkgs "vm-chat" "webtest")
      inputs.noctalia.packages.${sys}.default
      hyprpaper
      foot
      grim
      imagemagick
      curl
      jq
      socat
    ];

    systemd.tmpfiles.rules = [
      "d /home/pebor/.config/hypr 0755 pebor users -"
      "L+ /home/pebor/.config/hypr/hyprland.conf - - - - ${hyprlandConf pkgs}"
      "L+ /home/pebor/.config/hypr/hyprpaper.conf - - - - ${hyprpaperConf pkgs}"
    ];

    virtualisation.vmVariant.virtualisation = {
      memorySize = 2048;
      cores = 2;
      diskSize = 4096;
      graphics = false;
      qemu.options = [
        "-device" "virtio-vga"
        "-monitor" "unix:/tmp/vmtest-mon.sock,server=on,wait=off"
        "-chardev" "socket,id=vs,path=/tmp/vmtest-serial.sock,server=on,wait=off"
        "-serial" "chardev:vs"
      ];
    };

    systemd.services.vmtest-app = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = { Type = "oneshot"; User = "pebor"; };
      script = ''
        export XDG_RUNTIME_DIR=/run/user/1000
        for i in $(seq 1 90); do [ -S "$XDG_RUNTIME_DIR/wayland-1" ] && break; sleep 1; done
        export WAYLAND_DISPLAY=wayland-1
        MODE=$(cat /etc/vmtest-mode 2>/dev/null || echo launchpad)
        Q=$(cat /etc/vmtest-query 2>/dev/null || echo "ze")
        case "$MODE" in
          webtest) /run/current-system/sw/bin/vm-chat -url "$Q" & ;;
          watch)   /run/current-system/sw/bin/vm-watch & ;;
          *)       /run/current-system/sw/bin/vm-launchpad -q "$Q" & ;;
        esac
      '';
    };
  };
}
