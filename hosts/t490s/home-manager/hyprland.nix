{ pkgs, ... } : {

  wayland.windowManager.hyprland.settings = {
    bind = [
      "$mainMod, c, exec, rmenu -c -w 500 -s center -l horizontal -P Calculator"
      "$mainMod, n, exec, rmenu -w 500 -s center -P ..."
      "$mainMod, o, exec, ~/.config/hypr/otter.sh"
    ];
  };


}
