# GUI applications (superset of the old per-host copies).
# logseq moved here from the system profile (HM-side input now).
{ inputs, ... }:
{
  flake.modules.homeManager.packages-apps = { pkgs, ... }: {
    home.packages = with pkgs; [
      inputs.zen-browser.packages.${pkgs.system}.default # beta
      inputs.helium.packages.${pkgs.system}.default

      thinkfan

      pavucontrol
      fuzzel
      inputs.otter-launcher.packages.${pkgs.system}.default

      gnome-disk-utility

      evince
      zathura

      vscode

      opentabletdriver

      qemu

      vial

      # File managers
      nautilus
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

      telegram-desktop

      qbittorrent

      # Notes (from the logseq-nightly flake, follows nixpkgs-hm)
      inputs.logseq-nightly.packages.${pkgs.system}.logseq
      inputs.logseq-nightly.packages.${pkgs.system}.logseq-cli

      r2modman
      prismlauncher

      libreoffice-fresh
      hunspell
      hunspellDicts.cs_CZ
      hunspellDicts.en-us

      # Kept disabled intentionally (input retained in flake.nix):
      # inputs.affinity-nix.packages.x86_64-linux.v3

      popsicle

      godot
    ];
  };
}
