# GUI applications (superset of the old per-host copies).
# logseq moved here from the system profile (HM-side input now).
# Big/rarely-used apps (vscode, qemu, godot, libreoffice) live in
# packages-heavy.nix so fresh installs can skip them.
{ inputs, ... }:
{
  flake.modules.homeManager.packages-apps = { pkgs, ... }: {
    home.packages = with pkgs; [
      inputs.zen-browser.packages.${pkgs.stdenv.hostPlatform.system}.default # beta
      inputs.helium.packages.${pkgs.stdenv.hostPlatform.system}.default

      thinkfan

      pavucontrol
      fuzzel

      gnome-disk-utility

      evince
      zathura

      opentabletdriver

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
      inputs.logseq-nightly.packages.${pkgs.stdenv.hostPlatform.system}.logseq
      inputs.logseq-nightly.packages.${pkgs.stdenv.hostPlatform.system}.logseq-cli

      r2modman
      prismlauncher

      # Kept disabled intentionally (input retained in flake.nix):
      # inputs.affinity-nix.packages.x86_64-linux.v3

      popsicle
    ];
  };
}
