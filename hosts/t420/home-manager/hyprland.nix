{ pkgs, ... } : {

  wayland.windowManager.hyprland = {
    monitor = [
      ",preferred,0x0,1"
    ];
  };


}
