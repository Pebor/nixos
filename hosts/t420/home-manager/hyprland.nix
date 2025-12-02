{ pkgs, ... } : {

  wayland.windowManager.hyprland.settings = {
    monitor = [
      ",preferred,0x0,1"
    ];
  };


}
