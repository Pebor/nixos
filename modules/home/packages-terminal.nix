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

      antigravity-cli

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

      # opencode from the temporary nixpkgs-opencode pin (2.2.1): 2.2.5 in
      # unstable cannot build (NixOS/nixpkgs#582673). Revert to plain `opencode`
      # and drop the input once unstable ships a buildable 2.2.5.
      inputs.nixpkgs-opencode.legacyPackages.${pkgs.stdenv.hostPlatform.system}.opencode

      # pi (minimal harness): 4 tools, ~4x leaner requests than opencode,
      # uses the same OpenCode Go subscription. Kept side by side on purpose.
      pi-coding-agent
      nodejs_22 # `pi install` / `pi update` shell out to npm
    ];
  };
}
