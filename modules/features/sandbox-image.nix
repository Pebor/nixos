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

  # dbus (and other tools) resolve the running uid via /etc/passwd; the image
  # has none, which makes dbus-daemon die with "Memory allocation failure".
  passwdDb = pkgs.runCommand "hermes-sandbox-passwd" { } ''
    mkdir -p $out/etc
    printf 'root:x:0:0:root:/root:/bin/sh\nhermes:x:1001:100:hermes:/root:/bin/sh\n' > $out/etc/passwd
    printf 'root:x:0:\nusers:x:100:\n' > $out/etc/group
  '';

  # Chromium paints text only when fontconfig finds a config AND the fonts it
  # names. The image shipped neither: screenshots showed page backgrounds and
  # images but not one glyph (measured: every text run had zero height). The
  # generated fonts.conf names absolute store paths, so the fonts must be part
  # of `contents` too, not just referenced from the file.
  sandboxFonts = with pkgs; [ dejavu_fonts liberation_ttf noto-fonts ];
  sandboxFontsConf = pkgs.makeFontsConf { fontDirectories = sandboxFonts; };

  # Hermes' sandbox browser probe expects a Playwright layout
  # ($PLAYWRIGHT_BROWSERS_PATH/chromium-*/chrome-linux/chrome), so put the nix
  # chromium there instead of asking for a download.
  playwrightChromium = pkgs.runCommand "hermes-playwright-chromium" { } ''
    mkdir -p $out/opt/playwright/chromium-1208/chrome-linux
    ln -s ${pkgs.chromium}/bin/chromium $out/opt/playwright/chromium-1208/chrome-linux/chrome
  '';

  binPath = lib.makeBinPath tools;
in
{
  flake.packages.x86_64-linux.hermes-sandbox = pkgs.dockerTools.buildLayeredImage {
  name = "hermes-sandbox";
  tag = "latest";

  contents = tools ++ sandboxFonts ++ [    pkgs.dockerTools.binSh
    pkgs.dockerTools.usrBinEnv
    pkgs.dockerTools.caCertificates
    passwdDb
    playwrightChromium
  ];

  # `contents` cannot win here: the dbus package is part of `tools`, and its own
  # /etc/dbus-1/session.conf (a placeholder WITHOUT <listen>) is merged over any
  # second copy. extraCommands run last, so they replace the file for real.
  extraCommands = ''
    rm -f etc/dbus-1/session.conf
    mkdir -p etc/dbus-1
    cat > etc/dbus-1/session.conf <<'EOF'
    <!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
      "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
    <busconfig>
      <type>session</type>
      <listen>unix:tmpdir=/tmp</listen>
      <auth>EXTERNAL</auth>
      <policy context="default">
        <allow send_destination="*" eavesdrop="true"/>
        <allow eavesdrop="true"/>
        <allow own="*"/>
      </policy>
    </busconfig>
    EOF

    # fontconfig config for the sandbox chromium (see sandboxFontsConf). It is a
    # single FILE, so it cannot go in `contents`; FONTCONFIG_FILE in Env points here.
    mkdir -p etc/fonts
    cp ${sandboxFontsConf} etc/fonts/fonts.conf
  '';

  config = {
    Env = [
      "PATH=/usr/local/bin:${binPath}:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin"
      "LANG=C.UTF-8"
      "LC_ALL=C.UTF-8"
      "TERM=xterm-256color"
      "PLAYWRIGHT_BROWSERS_PATH=/opt/playwright"
      "PYTHONUNBUFFERED=1"
      "PYTHONDONTWRITEBYTECODE=1"
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
      "FONTCONFIG_FILE=/etc/fonts/fonts.conf"
    ];
    Cmd = [ "${pkgs.bashInteractive}/bin/bash" ];
    WorkingDir = "/home/server";
  };
  };

}
