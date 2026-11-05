# vmtest — Pebor's throwaway Hyprland test box on the t490s.
#
# Small: 2 GB RAM, 2 cores, sparse 4 GB disk. Uses his REAL generated
# hyprland.conf (pulled from his home-manager generation as a derivation), his
# wallpaper and his stylix palette, so visual tests reflect production.
#
# Host <-> VM:
#   /mnt/bin  (9p, ro)  the app binaries — swap them on the host, no rebuild
#   /mnt/out  (9p, rw)  readiness marker + logs
#   QEMU monitor socket /tmp/vmtest-mon.sock  -> screendump
# The guest console goes to stdio, i.e. ~/vmtest-out/vm.log on the host.
{ inputs, ... }:
let
  sys = "x86_64-linux";
  wallpaper = ../../resources/wallpapers/shaded_mountains.jpg;
  hyprConf = /nix/store/ckc3zgf2916ghki4vahp20nmyfiba9qg-hm_hyprhyprland.conf;

  mkApp = pkgs: name: bin: pkgs.writeShellScriptBin name ''
    export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath (with pkgs; [
      libx11 libxcursor libxrandr libxi libxcb libxkbcommon
      mesa vulkan-loader wayland fontconfig freetype
      glib gtk3 pango cairo gdk-pixbuf harfbuzz libepoxy
      webkitgtk_4_1 libsoup_3 glib-networking gtk-layer-shell
    ])}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export GIO_EXTRA_MODULES="${pkgs.glib-networking}/lib/gio/modules"
    exec /mnt/bin/${bin} "$@"
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

    imports =
      (with inputs.self.modules.nixos; [ nix-settings system hyprland stylix ])
      ++ [ inputs.home-manager.nixosModules.home-manager ];

    users.users.pebor = {
      isNormalUser = true;
      uid = 1000;
      extraGroups = [ "wheel" "video" "input" "render" ];
      password = "test";
      shell = pkgs.bash;
      createHome = true;
    };
    security.sudo.wheelNeedsPassword = false;
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
        home.file."nixos/resources/wallpapers/shaded_mountains.jpg".source = wallpaper;
      };
    };

    systemd.tmpfiles.rules = [
      "d /nix/var/nix/profiles/per-user/pebor 0755 pebor users -"
      "d /home/pebor/.config/hypr 0755 pebor users -"
      "L+ /home/pebor/.config/hypr/hyprland.conf - - - - ${hyprConf}"
      "d /home/pebor/.nix-profile/bin 0755 pebor users -"
      "L+ /home/pebor/.nix-profile/bin/launchpad - - - - /run/current-system/sw/bin/vm-launchpad"
      "L+ /home/pebor/.nix-profile/bin/agent-watch - - - - /run/current-system/sw/bin/vm-watch"
      "L+ /home/pebor/.nix-profile/bin/webtest - - - - /run/current-system/sw/bin/vm-chat"
      "d /mnt/bin 0755 root root -"
      "d /mnt/out 0777 root root -"
    ];

    environment.systemPackages = with pkgs; [
      (mkApp pkgs "vm-launchpad" "launchpad")
      (mkApp pkgs "vm-watch" "agent-watch")
      (mkApp pkgs "vm-chat" "webtest")
      hyprpaper noctalia foot grim imagemagick curl jq
    ];

    boot.supportedFilesystems = [ "9p" ];
    hardware.graphics.enable = true;
    hardware.graphics.enable32Bit = false;

    # 9p shares, mounted by a retrying unit (fstab gave up silently at boot)
    systemd.services.vmtest-mounts = {
      wantedBy = [ "multi-user.target" ];
      before = [ "vmtest-app.service" ];
      path = [ pkgs.util-linux pkgs.coreutils ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; StandardOutput = "journal+console"; StandardError = "journal+console"; };
      script = ''
        for i in $(seq 1 20); do
          mountpoint -q /mnt/bin || mount -t 9p vmbin /mnt/bin -o trans=virtio,version=9p2000.L,ro
          mountpoint -q /mnt/out || mount -t 9p vmout /mnt/out -o trans=virtio,version=9p2000.L
          if mountpoint -q /mnt/bin && mountpoint -q /mnt/out; then echo "VM_MOUNTS_OK"; exit 0; fi
          echo "mount attempt  failed"
          sleep 1
        done
        echo "VM_MOUNTS_FAILED"
        exit 1
      '';
    };

    virtualisation.vmVariant.virtualisation = {
      memorySize = 2048;
      cores = 2;
      diskSize = 4096;
      graphics = false;
      qemu.options = [
        "-device" "virtio-vga"
        "-monitor" "unix:/tmp/vmtest-mon.sock,server=on,wait=off"
        "-virtfs" "local,path=/home/server/vmtest-bin,mount_tag=vmbin,security_model=none,readonly=on"
        "-virtfs" "local,path=/home/server/vmtest-out,mount_tag=vmout,security_model=none"
      ];
    };

    systemd.services.vmtest-app = {
      wantedBy = [ "multi-user.target" ];
      after = [ "vmtest-mounts.service" ];
      wants = [ "vmtest-mounts.service" ];
      path = [ pkgs.coreutils pkgs.procps pkgs.bash pkgs.hyprland ];
      serviceConfig = {
        Type = "oneshot";
        User = "pebor";
        Environment = [ "LIBGL_ALWAYS_SOFTWARE=1" "GALLIUM_DRIVER=llvmpipe" "MYGO_SOFTWARE=1" ];
        StandardOutput = "journal+console";
        StandardError = "journal+console";
      };
      script = ''
        export XDG_RUNTIME_DIR=/run/user/1000
        for i in $(seq 1 90); do [ -S "$XDG_RUNTIME_DIR/wayland-1" ] && break; sleep 1; done
        export WAYLAND_DISPLAY=wayland-1
        # the host picks what to test: /mnt/bin/cmd.txt holds the command line
        CMD=$(cat /mnt/bin/cmd.txt 2>/dev/null || true)
        [ -n "$CMD" ] || CMD="/run/current-system/sw/bin/vm-launchpad -q ze"
        echo "VM_APP cmd=$CMD"
        sleep 20
        echo "DIAG launch"
        nohup bash -c $CMD > /tmp/app.log 2>&1 < /dev/null &
        sleep 6
        echo "DIAG log:"; head -15 /tmp/app.log
        echo "DIAG clients:"; hyprctl -j clients 2>&1 | head -c 300; echo
        echo "DIAG layers:"; hyprctl -j layers 2>&1 | head -c 400; echo
        echo "VM_APP_READY"
      '';
    };
  };
}
