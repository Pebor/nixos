{ pkgs, inputs, ...}: {
  home.packages = with pkgs; [
    inputs.zen-browser.packages."${system}".default # beta
    
    pavucontrol
    fuzzel
    walker

    gnome-disk-utility
    evince

    opentabletdriver

    qemu

    syncthing
    vial

    # File managers
    nautilus
    nautilus-open-any-terminal
    filezilla
    cosmic-files

    mpv
    feh
    webtorrent_desktop
    spotify
    syncplay

    telegram-desktop

    qbittorrent
    krita
    inkscape
    # webcord-vencord
    # nwg-look
    # godot

    obsidian
    logseq

    lutris
    r2modman
    prismlauncher

    libreoffice-fresh
    hunspell
    hunspellDicts.cs_CZ
    hunspellDicts.en-us

    inputs.affinity-nix.packages.x86_64-linux.v3

    popsicle
  ];
}
