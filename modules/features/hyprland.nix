# Hyprland — the whole feature in one file.
#
# The NixOS aspect only provides the session; the Home Manager aspect owns
# the user session: settings, hypridle, hyprlock and hyprpaper.
#
# FIX (previously): the NixOS config enabled `services.hypridle` system-wide
# with empty settings while HM configured it — the two definitions fought and
# hypridle behaved differently than the HM file said. Now only HM manages it.
{ inputs, ... }:
{
  flake.modules.nixos.hyprland = { lib, ... }: {
    programs.hyprland.enable = true;
    programs.hyprlock.enable = true; # needed for the hyprlock PAM service
    programs.xwayland.enable = true;

    # The nixpkgs hyprlock module unconditionally sets
    # `services.hypridle.enable = true` ("hyprlock needs hypridle"),
    # which spawns a SECOND, system-side hypridle with empty settings that
    # fights the HM one (this was the root cause of "hypridle behaves
    # differently than configured"). The user session owns hypridle —
    # see the homeManager aspect below — so force it off here.
    services.hypridle.enable = lib.mkForce false;
  };

  flake.modules.homeManager.hyprland = { pkgs, ... }: {
    home.packages = with pkgs; [
      hyprpaper
      dunst
      waybar
      tofi
      brightnessctl
      inputs.rose-pine-hyprcursor.packages.${pkgs.system}.default
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
      # Keep the legacy config type (matches existing stateVersion).
      configType = "hyprlang";
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
          "waybar"
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
          preserve_split = true;
        };

        master = {
          new_status = "master";
        };

        # Misc
        misc = {
          force_default_wallpaper = -1;
          disable_hyprland_logo = false;
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
      };
    };

    # The ONLY hypridle definition now (previously also enabled system-wide
    # with empty settings, which overrode this one).
    services.hypridle = {
      enable = true;
      settings = {
        general = {
          lock_cmd = "pidof hyprlock || hyprlock"; # avoid starting multiple hyprlock instances.
          before_sleep_cmd = "loginctl lock-session"; # lock before suspend.
          after_sleep_cmd = "hyprctl dispatch dpms on"; # to avoid having to press a key twice to turn on the display.
        };

        listener = [
          {
            timeout = 150; # 2.5min.
            on-timeout = "brightnessctl -s set 10"; # set monitor backlight to minimum, avoid 0 on OLED monitor.
            on-resume = "brightnessctl -r"; # monitor backlight restore.
          }
          {
            timeout = 150; # 2.5min.
            on-timeout = "brightnessctl -sd rgb:kbd_backlight set 0"; # turn off keyboard backlight.
            on-resume = "brightnessctl -rd rgb:kbd_backlight"; # turn on keyboard backlight.
          }
          {
            timeout = 600; # 5min
            on-timeout = "loginctl lock-session"; # lock screen when timeout has passed
          }
          {
            timeout = 300; # 5.5min
            on-timeout = "hyprctl dispatch dpms off"; # screen off when timeout has passed
            on-resume = "hyprctl dispatch dpms on"; # screen on when activity is detected after timeout has fired.
          }
          {
            timeout = 1200; # 30min
            on-timeout = "systemctl suspend"; # suspend pc
          }
        ];
      };
    };

    programs.hyprlock = {
      enable = true;
      settings = {
        background = {
          monitor = "";
          path = "screenshot"; # supports png, jpg, webp (no animations, though)

          # all these options are taken from hyprland, see https://wiki.hyprland.org/Configuring/Variables/#blur for explanations
          blur_passes = 1; # 0 disables blurring
          blur_size = 7;
          noise = 0.0117;
          contrast = 0.8916;
          brightness = 0.8172;
          vibrancy = 0.1696;
          vibrancy_darkness = 0.0;
        };

        shape = [
          {
            monitor = "";
            size = "460, 460";
            color = "rgb(0F0F17)";
            border_size = 8;
            border_color = "rgb(E4C9AF)";
            rotate = 65;
            xray = false; # if true, make a "hole" in the background (rectangle of specified size, no rotation)
            position = "0, -20";
            halign = "center";
            valign = "center";
          }
          {
            monitor = "";
            size = "460, 460";
            color = "rgb(0F0F17)";
            border_size = 8;
            border_color = "rgb(A6D189)";
            rotate = 55;
            xray = false;
            position = "0, -20";
            halign = "center";
            valign = "center";
          }
          {
            monitor = "";
            size = "460, 460";
            color = "rgb(0F0F17)";
            border_size = 8;
            border_color = "rgb(A1BDCE)";
            rotate = 45;
            xray = false;
            position = "0, -20";
            halign = "center";
            valign = "center";
          }
        ];

        input-field = [
          {
            monitor = "";
            size = "200, 50";
            dots_size = "0.33"; # Scale of input-field height, 0.2 - 0.8
            dots_spacing = "0.15"; # Scale of dots' absolute size, 0.0 - 1.0
            dots_center = false;
            dots_rounding = -1; # -1 default circle, -2 follow input-field rounding
            outer_color = "rgb(161, 189, 206)";
            inner_color = "rgba(200, 200, 200, 0.1)";
            font_color = "rgb(10, 10, 10)";
            fade_on_empty = true;
            fade_timeout = 1000; # Milliseconds before fade_on_empty is triggered.
            placeholder_text = "<i>Input Password...</i>"; # Text rendered in the input box when it's empty.
            hide_input = false;
            rounding = 10; # -1 means complete rounding (circle/oval)
            check_color = "rgba(204, 136, 34, 0.1)";
            fail_color = "rgb(204, 34, 34)"; # if authentication failed, changes outer_color and fail message color
            fail_text = "<i>$FAIL <b>($ATTEMPTS)</b></i>"; # can be set to empty
            fail_timeout = 2000; # milliseconds before fail_text and fail_color disappears
            fail_transition = 300; # transition time in ms between normal outer_color and fail_color
            capslock_color = -1;
            numlock_color = -1;
            bothlock_color = -1; # when both locks are active. -1 means don't change outer color (same for above)
            invert_numlock = false; # change color if numlock is off
            swap_font_color = false;

            position = "0, -20";
            halign = "center";
            valign = "center";
          }
        ];
      };
    };

    services.hyprpaper = {
      enable = true;
      settings = {
        ipc = false;
        splash = false;

        wallpaper = [
          {
            monitor = "";
            path = "~/nixos/resources/wallpapers/shaded_mountains.jpg";
          }
        ];
      };
    };
  };
}
