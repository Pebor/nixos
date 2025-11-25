{ inputs, pkgs, ... } : {
  home.packages = with pkgs; [
    hyprpaper
    dunst
    waybar    
    tofi
    brightnessctl
    inputs.rose-pine-hyprcursor.packages.${system}.default
    wofi-emoji
    wleave
    grimblast
    wl-clipboard

    libnotify
    libqalculate
    libinput
    libwacom

    rose-pine-cursor
    rose-pine-gtk-theme
    rose-pine-icon-theme

    quickshell
  ];
}
