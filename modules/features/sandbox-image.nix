# Hermes shell sandbox — the container the *native* Hermes agent executes its
# terminal / file / execute_code calls in (`terminal.backend = "docker"`).
#
# Why nix-built: the agent's environment is disposable, but its toolchain must be
# reproducible and reviewable. This file IS the tool list; `nix build` replaces
# `docker build`, and a tool change is a one-line diff in git.
#
# Build (on the host — the agent container has no nix):
#   nix build ~/nixos#hermes-sandbox && docker load < result
#
# Everything lives under /nix/store inside the image, so the image is
# self-contained: do NOT bind-mount the host /nix over it (that would shadow the
# image's own store paths). Extra tools are a rebuild + git diff, not pip/apt.
{ inputs, ... }:
let
  pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
  lib = pkgs.lib;
  # LaTeX for manim's MathTex (\mathds needs doublestroke). scheme-small keeps the
  # image ~300 MB instead of pulling full TeX Live.
  tex = pkgs.texlive.combine {
    inherit (pkgs.texlive)
      scheme-small
      dvisvgm
      standalone
      doublestroke
      ;
  };

  tools = with pkgs; [
    # shell + core utilities
    bashInteractive
    coreutils
    findutils
    gnused
    gnugrep
    gawk
    diffutils
    patch
    which
    file
    less
    procps
    psmisc
    util-linux
    gnutar
    gzip
    xz
    unzip
    zip
    cacert

    # network + repo work
    curl
    wget
    openssh
    git
    jq
    yq-go
    ripgrep
    fd
    tree
    rsync

    # editors + multiplexer
    vim
    tmux

    # languages + package managers
    python3
    python3Packages.pip
    python3Packages.virtualenv
    uv
    nodejs_22
    pnpm

    # media + documents
    ffmpeg
    imagemagick
    poppler-utils
    pandoc
    ghostscript

    # animation
    manim
    tex

    # browser automation (browser_exec / Bot Desktop)
    chromium
    tigervnc
    xfwm4
    xfce4-panel
    xfdesktop
    xfconf
    xfce4-settings
    dbus
    xorg.xauth
    xorg.xdpyinfo
    xorg.xprop

    # container management from inside the sandbox (socket is bind-mounted)
    docker-client

    # misc
    sqlite
    openssl
    gnupg
  ];

  # Bot Desktop starts its session bus with `dbus-run-session`, which reads
  # /etc/dbus-1/session.conf — in the nix dbus package that file is a placeholder
  # WITHOUT <listen>, so the bus refuses to start ("needs one or more <listen>").
  # This wrapper points it at the package's real session.conf and sits first in
  # PATH, so no /etc write is needed.
  dbusRun = pkgs.runCommand "hermes-dbus-run-session" { } ''
    mkdir -p $out/usr/local/bin
    cat > $out/usr/local/bin/dbus-run-session <<'EOF'
    #!/bin/sh
    exec ${pkgs.dbus}/bin/dbus-run-session \
      --config-file=${pkgs.dbus}/share/dbus-1/session.conf "$@"
    EOF
    chmod +x $out/usr/local/bin/dbus-run-session
  '';

  # dbus (and other tools) resolve the running uid via /etc/passwd; the image
  # has none, which makes dbus-daemon die with "Memory allocation failure".
  passwdDb = pkgs.runCommand "hermes-sandbox-passwd" { } ''
    mkdir -p $out/etc
    printf 'root:x:0:0:root:/root:/bin/sh\nhermes:x:1001:100:hermes:/root:/bin/sh\n' > $out/etc/passwd
    printf 'root:x:0:\nusers:x:100:\n' > $out/etc/group
  '';

  binPath = lib.makeBinPath tools;
in
{
  flake.packages.x86_64-linux.hermes-sandbox = pkgs.dockerTools.buildLayeredImage {
  name = "hermes-sandbox";
  tag = "latest";

  contents = tools ++ [    pkgs.dockerTools.binSh
    pkgs.dockerTools.usrBinEnv
    pkgs.dockerTools.caCertificates
    dbusRun
    passwdDb
  ];

  config = {
    Env = [
      "PATH=/usr/local/bin:${binPath}:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin"
      "LANG=C.UTF-8"
      "LC_ALL=C.UTF-8"
      "TERM=xterm-256color"
      "PYTHONUNBUFFERED=1"
      "PYTHONDONTWRITEBYTECODE=1"
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
    ];
    Cmd = [ "${pkgs.bashInteractive}/bin/bash" ];
    WorkingDir = "/home/server";
  };
  };

}
