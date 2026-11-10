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

    # container management from inside the sandbox (socket is bind-mounted)
    docker-client

    # misc
    sqlite
    openssl
    gnupg
  ];

  binPath = lib.makeBinPath tools;
in
{
  flake.packages.x86_64-linux.hermes-sandbox = pkgs.dockerTools.buildLayeredImage {
  name = "hermes-sandbox";
  tag = "latest";

  contents = tools ++ [
    pkgs.dockerTools.binSh
    pkgs.dockerTools.usrBinEnv
    pkgs.dockerTools.caCertificates
  ];

  config = {
    Env = [
      "PATH=${binPath}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
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
