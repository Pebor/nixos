{ pkgs, inputs, ... } : {
  home.packages = with pkgs; [
    # Terminals
    foot
    
    git

    inputs.helix.packages."${system}".default

    nh
    comma
    nix-index

    aichat
    ollama
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

    nushell

    fastfetch
    powertop
    bluetui
    spotify-player
    systemctl-tui
    lazygit

    zellij
    yazi
  ];
}
