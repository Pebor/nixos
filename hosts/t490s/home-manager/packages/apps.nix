{ pkgs, inputs, ...}: {
  home.packages = with pkgs; [
    inputs.zen-browser.packages."${system}".default # beta
    inputs.helium.packages."${system}".default
    
    thinkfan
    
    pavucontrol
    fuzzel
    # walker
    inputs.otter-launcher.packages."x86_64-linux".default

    gnome-disk-utility

    evince
    zathura

    vscode

    opentabletdriver

    qemu

    # syncthing
    vial

    # File managers
    nautilus
    # nautilus-open-any-terminal
    # filezilla
    cosmic-files
    cosmic-reader
    cosmic-edit
    cosmic-term
    kdePackages.qtsvg
    kdePackages.dolphin

    mpv
    feh
    webtorrent_desktop
    spotify
    # syncplay

    telegram-desktop

    qbittorrent
    # krita
    # inkscape
    # webcord-vencord
    # nwg-look
    # godot

    # obsidian
    # siyuan

    # lutris
    r2modman
    prismlauncher

    libreoffice-fresh
    hunspell
    hunspellDicts.cs_CZ
    hunspellDicts.en-us

    # inputs.affinity-nix.packages.x86_64-linux.v3

    popsicle
    # ventoy

    godot
  ];
}
