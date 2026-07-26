{ pkgs, inputs, ... } : {
  home.packages = with pkgs; [
    # Terminals
    foot
    ratty
    # ghostty
    
    git
    jujutsu

    inputs.helix.packages."${system}".default

    nh
    comma
    nix-index

    # aichat
    # ollama
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
    # impala
    spotify-player
    systemctl-tui
    lazygit

    zellij
    yazi

    opencode
  ];
}
