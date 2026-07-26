# Terminal programs (superset of the old per-host copies).
{ inputs, ... }:
{
  flake.modules.homeManager.packages-terminal = { pkgs, ... }: {
    home.packages = with pkgs; [
      # Terminals
      foot
      ratty

      git
      jujutsu

      inputs.helix.packages.${pkgs.system}.default

      nh
      comma
      nix-index

      gemini-cli

      btop
      bottom

      bat
      eza
      dust
      ripgrep
      jq
      tldr

      ffmpeg
      imagemagick

      nushell
      brush

      fastfetch
      powertop
      bluetui
      spotify-player
      systemctl-tui
      lazygit

      zellij
      yazi

      opencode
    ];
  };
}
