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

      inputs.helix.packages.${pkgs.stdenv.hostPlatform.system}.default

      nh
      comma
      nix-index

      antigravity-cli # gemini-cli was removed upstream, replaced by this

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
