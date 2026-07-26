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
  ];

  wayland.windowManager.hyprland = {
    enable = true;
    settings = {
      # Monitors
      monitor = [
        ",preferred,0x1080,1"
        "HDMI-A-2,preferred,0x0,1"
      ];

      # Variables
      "$terminal" = "foot";
      "$fileManager" = "nautilus";
      "$menu" = "wofi --show drun";

      # Autostart
      "exec-once" = [
        # "dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP"
        # "dbus-update-activation-environment --systemd --all"
        # "systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP"
        "waybar"
        # "libinput-gestures"
        # "fprintd"
        # "hypridle"
        # "hyprpaper"
        "dunst"
        "systemctl --user start plasma-polkit-agent"
      ];

      # Environment variables
      env = [
        "XDG_CURRENT_DESKTOP,Hyprland"
        "XDG_SESSION_TYPE,wayland"
        "XDG_SESSION_DESKTOP,Hyprland"
        "QT_QPA_PLATFORM,wayland;xcb"
        "QT_QPA_PLATFORMTHEME,qt6ct"
        "QT_WAYLAND_DISABLE_WINDOWDECORATION,1"
        "QT_AUTO_SCREEN_SCALE_FACTOR,1"
        "MOZ_ENABLE_WAYLAND,1"
        "GDK_SCALE,1"
        "XCURSOR_SIZE,32"
        "HYPRCURSOR_SIZE,32"
        "HYPRCURSOR_THEME,rose-pine-hyprcursor"
      ];

      # General settings
      general = {
        gaps_in = 5;
        gaps_out = 7;
        border_size = 2;
        "col.active_border" = "0xffA1BDCE";
        "col.inactive_border" = "rgba(595959aa)";
        resize_on_border = false;
        allow_tearing = true;
        layout = "dwindle";
      };

      # Decoration
      decoration = {
        rounding = 0;
        active_opacity = 1.0;
        inactive_opacity = 1.0;
        blur = {
          enabled = false;
          size = 3;
          passes = 1;
          vibrancy = 0.1696;
          new_optimizations = true;
        };
      };

      # Animations
      animations = {
        enabled = false;
        bezier = [
          "easeOutQuint,0.23,1,0.32,1"
          "easeInOutCubic,0.65,0.05,0.36,1"
          "linear,0,0,1,1"
          "almostLinear,0.5,0.5,0.75,1.0"
          "quick,0.15,0,0.1,1"
        ];
        animation = [
          "global, 1, 10, default"
          "border, 1, 5.39, easeOutQuint"
          "windows, 1, 4.79, easeOutQuint"
          "windowsIn, 1, 4.1, easeOutQuint, popin 87%"
          "windowsOut, 1, 1.49, linear, popin 87%"
          "fadeIn, 1, 1.73, almostLinear"
          "fadeOut, 1, 1.46, almostLinear"
          "fade, 1, 3.03, quick"
          "layers, 1, 3.81, easeOutQuint"
          "layersIn, 1, 4, easeOutQuint, fade"
          "layersOut, 1, 1.5, linear, fade"
          "fadeLayersIn, 1, 1.79, almostLinear"
          "fadeLayersOut, 1, 1.39, almostLinear"
          "workspaces, 1, 1.94, almostLinear, fade"
          "workspacesIn, 1, 1.21, almostLinear, fade"
          "workspacesOut, 1, 1.94, almostLinear, fade"
        ];
      };

      # Layouts
      dwindle = {
        # pseudotile = true;
        preserve_split = true;
      };

      master = {
        new_status = "master";
      };

      # Misc
      misc = {
        force_default_wallpaper = -1;
        disable_hyprland_logo = false;
        # vfr = true;
        on_focus_under_fullscreen = 1;
      };

      # Input
      input = {
        kb_layout = "cz,cz";
        kb_variant = "coder,";
        kb_options = "grp:alt_ctrl_toggle";
        follow_mouse = 1;
        sensitivity = 0;
        repeat_delay = 200;
        touchpad = {
          natural_scroll = true;
          scroll_factor = 0.7;
          drag_lock = true;
        };
      };

      # Gestures
      gesture = [
        "3, horizontal, workspace"
        "3, up, scale: 1.5, fullscreen"
      ];
      
      # Per-device config
      device = [{
        name = "epic-mouse-v1";
        sensitivity = -0.5;
      }];

      # Group
      group = {
        groupbar = {
            stacked = true;
            render_titles = false;
        };
      };

      # Keybindings
      "$mainMod" = "SUPER";
      bind = [
        "$mainMod, RETURN, exec, $terminal"
        # "$mainMod, RETURN, exec, foot -e zellij"
        # "$mainMod CTRL, RETURN, exec, foot"
        "$mainMod, M, exec, wofi-emoji"
        "$mainMod, E, exec, $fileManager"
        "$mainMod SHIFT, E, exec, foot -e yazi"
        "$mainMod, V, togglefloating,"
        "$mainMod, SPACE, exec, tofi-drun --drun-launch=true"
        "$mainMod CTRL, SPACE, exec, tofi-run | xargs hyprctl dispatch exec --"
        "$mainMod SHIFT, SPACE, exec, tofi-run | xargs hyprctl dispatch exec foot --"
        "$mainMod SHIFT, P, exec, hyprpicker -a"
        "$mainMod, P, pseudo,"
        "$mainMod, Q, killactive"
        "$mainMod, mouse:274, killactive"
        "$mainMod, PRINT, exec, grimblast copy output"
        "$mainMod SHIFT, PRINT, exec, grimblast copy area"
        "$mainMod CTRL, PRINT, exec, grimblast copy active"
        "$mainMod CTRL, L, exec, hyprlock"
        "$mainMod SHIFT, Q, exec, wleave"
        "$mainMod, F, fullscreen, 0"
        "$mainMod CTRL, F, fullscreen, 1"
        "$mainMod, W, togglegroup"
        "$mainMod, N, changegroupactive, f"
        "$mainMod SHIFT, N, changegroupactive, b"
        "$mainMod, l, movefocus, l"
        "$mainMod, h, movefocus, r"
        "$mainMod, k, movefocus, u"
        "$mainMod, j, movefocus, d"
        "$mainMod, 1, workspace, 1"
        "$mainMod, 2, workspace, 2"
        "$mainMod, 3, workspace, 3"
        "$mainMod, 4, workspace, 4"
        "$mainMod, 5, workspace, 5"
        "$mainMod, 6, workspace, 6"
        "$mainMod, 7, workspace, 7"
        "$mainMod, 8, workspace, 8"
        "$mainMod, 9, workspace, 9"
        "$mainMod SHIFT, 1, movetoworkspace, 1"
        "$mainMod SHIFT, 2, movetoworkspace, 2"
        "$mainMod SHIFT, 3, movetoworkspace, 3"
        "$mainMod SHIFT, 4, movetoworkspace, 4"
        "$mainMod SHIFT, 5, movetoworkspace, 5"
        "$mainMod SHIFT, 6, movetoworkspace, 6"
        "$mainMod SHIFT, 7, movetoworkspace, 7"
        "$mainMod SHIFT, 8, movetoworkspace, 8"
        "$mainMod SHIFT, 9, movetoworkspace, 9"
        "$mainMod, S, togglespecialworkspace, magic"
        "$mainMod SHIFT, S, movetoworkspace, special:magic"
        "$mainMod, mouse_down, workspace, e+1"
        "$mainMod, mouse_up, workspace, e-1"
      ];

      bindm = [
        "$mainMod, mouse:272, movewindow"
        "$mainMod SHIFT, mouse:272, resizewindow"
        "$mainMod, mouse:273, resizewindow"
      ];

      bindel = [
        ",XF86AudioRaiseVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+"
        ",XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"
        ",XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
        ",XF86AudioMicMute, exec, wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"
        ",XF86MonBrightnessUp, exec, brightnessctl s 10%+"
        ",XF86MonBrightnessDown, exec, brightnessctl s 10%-"
      ];

      # # Window Rules
      # windowrulev2 = [
      #   "suppressevent maximize, class:.*"
      #   "immediate, class:Minecraft"
      # ];
    };
  };
}
