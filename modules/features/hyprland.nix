# Hyprland — the whole feature in one file.
#
# Hyprland 0.57 dropped hyprlang entirely: Hyprland only reads
# $XDG_CONFIG_HOME/hypr/hyprland.lua now. Home Manager can still generate
# that file, but with `configType = "lua"` the `settings` attrset has to be
# written in the Lua API shape (hl.config{...}, hl.bind(...), hl.dsp.*) and it
# cannot express a start hook or anything dynamic. So the session config lives
# in `extraConfig` as plain Lua below, and hosts extend it with `lib.mkAfter`
# snippets of the same shape (see host-t14 / host-desktop).
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

  flake.modules.homeManager.hyprland =
    { pkgs, lib, config, ... }:
    let
      cfg = config.my.hyprland;

      # hl.on("hyprland.start", ...) body — one exec_cmd per autostart entry.
      autostartLua = lib.concatMapStringsSep "\n" (
        cmd: "  hl.exec_cmd(${lib.strings.toJSON cmd})"
      ) cfg.autostart;
    in
    {
      options.my.hyprland.autostart = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "waybar"
          "dunst"
          "systemctl --user start plasma-polkit-agent"
        ];
        description = ''
          Commands started on Hyprland start. Hosts that run a different
          shell (t14: noctalia) override this with `lib.mkForce`.
        '';
      };

      config = {
        home.packages = with pkgs; [
          hyprpaper
          dunst
          waybar
          tofi
          gtk-layer-shell
          webkitgtk_4_1
          glib-networking
          brightnessctl
          inputs.rose-pine-hyprcursor.packages.${pkgs.stdenv.hostPlatform.system}.default
          wofi-emoji
          wleave
          grimblast
          wl-clipboard

          # Provides the plasma-polkit-agent user unit started on startup.
          kdePackages.polkit-kde-agent-1

          libnotify
          libqalculate
          libinput
          libwacom

          rose-pine-cursor
          # rose-pine-gtk-theme
          rose-pine-icon-theme
        ];

        wayland.windowManager.hyprland = {
          enable = true;
          configType = "lua"; # Hyprland 0.57+ is lua-only

          # `settings` is left empty on purpose: with configType = "lua" it
          # renders `hl.<name>(<value>)` calls, which cannot express a start
          # hook, and the whole config is easier to read as Lua next to the
          # upstream examples. Hosts append their own Lua at the end.
          extraConfig = lib.mkBefore ''
            -- ═══ generated from modules/features/hyprland.nix ═══

            local mainMod     = "SUPER"
            local terminal    = "foot"
            local fileManager = "nautilus"
            local menu        = "wofi --show drun"

            -- ─── monitors ───────────────────────────────────────────────
            hl.monitor({ output = "", mode = "preferred", position = "0x1080", scale = 1 })
            hl.monitor({ output = "HDMI-A-2", mode = "highrr", position = "0x0", scale = 1 })
            hl.monitor({ output = "HDMI-A-1", mode = "highrr", position = "0x0", scale = 1 })

            -- ─── environment ────────────────────────────────────────────
            hl.env("XDG_CURRENT_DESKTOP", "Hyprland")
            hl.env("XDG_SESSION_TYPE", "wayland")
            hl.env("XDG_SESSION_DESKTOP", "Hyprland")
            hl.env("QT_QPA_PLATFORM", "wayland;xcb")
            hl.env("QT_QPA_PLATFORMTHEME", "qt6ct")
            hl.env("QT_WAYLAND_DISABLE_WINDOWDECORATION", "1")
            hl.env("QT_AUTO_SCREEN_SCALE_FACTOR", "1")
            hl.env("MOZ_ENABLE_WAYLAND", "1")
            hl.env("GDK_SCALE", "1")
            hl.env("XCURSOR_SIZE", "32")
            hl.env("HYPRCURSOR_SIZE", "32")
            hl.env("HYPRCURSOR_THEME", "rose-pine-hyprcursor")

            -- ─── start ──────────────────────────────────────────────────
            hl.on("hyprland.start", function()
            ${autostartLua}
            end)

            -- ─── look and feel ──────────────────────────────────────────
            hl.config({
              general = {
                gaps_in      = 5,
                gaps_out     = 7,
                border_size  = 2,
                col = {
                  active_border   = "0xffA1BDCE",
                  inactive_border = "rgba(595959aa)",
                },
                resize_on_border = false,
                allow_tearing    = true,
                layout           = "dwindle",
              },

              decoration = {
                rounding         = 0,
                active_opacity   = 1.0,
                inactive_opacity = 1.0,
                blur = {
                  enabled           = false,
                  size              = 3,
                  passes            = 1,
                  vibrancy          = 0.1696,
                  new_optimizations = true,
                },
              },

              animations = { enabled = false },

              dwindle = { preserve_split = true },
              master  = { new_status = "master" },

              misc = {
                force_default_wallpaper  = -1,
                disable_hyprland_logo    = false,
                on_focus_under_fullscreen = 1,
              },

              input = {
                kb_layout    = "cz,cz",
                kb_variant   = "coder,",
                kb_options   = "grp:alt_ctrl_toggle",
                follow_mouse = 1,
                sensitivity  = 0.2,
                repeat_delay = 200,
                touchpad = {
                  natural_scroll = true,
                  scroll_factor  = 0.7,
                  drag_lock      = true,
                },
              },

              group = {
                groupbar = {
                  stacked       = true,
                  render_titles = false,
                },
              },
            })

            -- ─── curves / animations (inert while animations.enabled = false)
            hl.curve("easeOutQuint",   { type = "bezier", points = { {0.23, 1},    {0.32, 1} } })
            hl.curve("easeInOutCubic", { type = "bezier", points = { {0.65, 0.05}, {0.36, 1} } })
            hl.curve("linear",         { type = "bezier", points = { {0, 0},       {1, 1} } })
            hl.curve("almostLinear",   { type = "bezier", points = { {0.5, 0.5},   {0.75, 1.0} } })
            hl.curve("quick",          { type = "bezier", points = { {0.15, 0},    {0.1, 1} } })

            hl.animation({ leaf = "global",        enabled = true, speed = 10,   bezier = "default" })
            hl.animation({ leaf = "border",        enabled = true, speed = 5.39, bezier = "easeOutQuint" })
            hl.animation({ leaf = "windows",       enabled = true, speed = 4.79, bezier = "easeOutQuint" })
            hl.animation({ leaf = "windowsIn",     enabled = true, speed = 4.1,  bezier = "easeOutQuint", style = "popin 87%" })
            hl.animation({ leaf = "windowsOut",    enabled = true, speed = 1.49, bezier = "linear",       style = "popin 87%" })
            hl.animation({ leaf = "fadeIn",        enabled = true, speed = 1.73, bezier = "almostLinear" })
            hl.animation({ leaf = "fadeOut",       enabled = true, speed = 1.46, bezier = "almostLinear" })
            hl.animation({ leaf = "fade",          enabled = true, speed = 3.03, bezier = "quick" })
            hl.animation({ leaf = "layers",        enabled = true, speed = 3.81, bezier = "easeOutQuint" })
            hl.animation({ leaf = "layersIn",      enabled = true, speed = 4,    bezier = "easeOutQuint", style = "fade" })
            hl.animation({ leaf = "layersOut",     enabled = true, speed = 1.5,  bezier = "linear",       style = "fade" })
            hl.animation({ leaf = "fadeLayersIn",  enabled = true, speed = 1.79, bezier = "almostLinear" })
            hl.animation({ leaf = "fadeLayersOut", enabled = true, speed = 1.39, bezier = "almostLinear" })
            hl.animation({ leaf = "workspaces",    enabled = true, speed = 1.94, bezier = "almostLinear", style = "fade" })
            hl.animation({ leaf = "workspacesIn",  enabled = true, speed = 1.21, bezier = "almostLinear", style = "fade" })
            hl.animation({ leaf = "workspacesOut", enabled = true, speed = 1.94, bezier = "almostLinear", style = "fade" })

            -- ─── gestures ───────────────────────────────────────────────
            hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })
            hl.gesture({ fingers = 3, direction = "up", action = "fullscreen", scale = 1.5 })

            -- ─── devices ────────────────────────────────────────────────
            hl.device({ name = "epic-mouse-v1", sensitivity = -0.5 })

            -- ─── keybindings ────────────────────────────────────────────
            hl.bind(mainMod .. " + RETURN",  hl.dsp.exec_cmd(terminal))
            hl.bind(mainMod .. " + M",       hl.dsp.exec_cmd("wofi-emoji"))
            hl.bind(mainMod .. " + E",       hl.dsp.exec_cmd(fileManager))
            hl.bind(mainMod .. " + SHIFT + E", hl.dsp.exec_cmd("foot -e yazi"))
            hl.bind(mainMod .. " + V",       hl.dsp.window.float({ action = "toggle" }))
            hl.bind(mainMod .. " + SPACE",   hl.dsp.exec_cmd("tofi-drun --drun-launch=true"))
            hl.bind(mainMod .. " + CTRL + SPACE",  hl.dsp.exec_cmd("tofi-run | xargs -r hyprctl dispatch exec --"))
            hl.bind(mainMod .. " + SHIFT + SPACE", hl.dsp.exec_cmd("tofi-run | xargs -r hyprctl dispatch exec foot --"))
            hl.bind(mainMod .. " + SHIFT + P", hl.dsp.exec_cmd("hyprpicker -a"))
            hl.bind(mainMod .. " + P",       hl.dsp.window.pseudo())
            hl.bind(mainMod .. " + Q",       hl.dsp.window.close())
            hl.bind(mainMod .. " + mouse:274", hl.dsp.window.close(), { mouse = true })
            hl.bind(mainMod .. " + PRINT",        hl.dsp.exec_cmd("grimblast copy output"))
            hl.bind(mainMod .. " + SHIFT + PRINT", hl.dsp.exec_cmd("grimblast copy area"))
            hl.bind(mainMod .. " + CTRL + PRINT",  hl.dsp.exec_cmd("grimblast copy active"))
            hl.bind(mainMod .. " + CTRL + L", hl.dsp.exec_cmd("hyprlock"))
            hl.bind(mainMod .. " + SHIFT + Q", hl.dsp.exec_cmd("wleave"))
            hl.bind(mainMod .. " + F",       hl.dsp.window.fullscreen({ mode = "fullscreen" }))
            hl.bind(mainMod .. " + CTRL + F", hl.dsp.window.fullscreen({ mode = "maximized" }))
            hl.bind(mainMod .. " + W",       hl.dsp.group.toggle())
            hl.bind(mainMod .. " + N",       hl.dsp.group.next())
            hl.bind(mainMod .. " + SHIFT + N", hl.dsp.group.prev())

            -- vim-ish focus (cz-coder layout: h/l are swapped on purpose)
            hl.bind(mainMod .. " + l", hl.dsp.focus({ direction = "left" }))
            hl.bind(mainMod .. " + h", hl.dsp.focus({ direction = "right" }))
            hl.bind(mainMod .. " + k", hl.dsp.focus({ direction = "up" }))
            hl.bind(mainMod .. " + j", hl.dsp.focus({ direction = "down" }))

            for i = 1, 9 do
              hl.bind(mainMod .. " + " .. i,             hl.dsp.focus({ workspace = i }))
              hl.bind(mainMod .. " + SHIFT + " .. i,     hl.dsp.window.move({ workspace = i }))
            end

            hl.bind(mainMod .. " + S",         hl.dsp.workspace.toggle_special("magic"))
            hl.bind(mainMod .. " + SHIFT + S", hl.dsp.window.move({ workspace = "special:magic" }))
            hl.bind(mainMod .. " + R",         hl.dsp.exec_cmd("~/.nix-profile/bin/launchpad"))
            hl.bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
            hl.bind(mainMod .. " + mouse_up",   hl.dsp.focus({ workspace = "e-1" }))

            -- mouse: move/resize by dragging
            hl.bind(mainMod .. " + mouse:272",         hl.dsp.window.drag(),   { mouse = true })
            hl.bind(mainMod .. " + SHIFT + mouse:272", hl.dsp.window.resize(), { mouse = true })
            hl.bind(mainMod .. " + mouse:273",         hl.dsp.window.resize(), { mouse = true })

            -- media / brightness keys (locked = works on the lockscreen,
            -- repeating = keep firing while held)
            local mediaOpts = { locked = true, repeating = true }
            hl.bind("XF86AudioRaiseVolume",  hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+"), mediaOpts)
            hl.bind("XF86AudioLowerVolume",  hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"), mediaOpts)
            hl.bind("XF86AudioMute",         hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"), mediaOpts)
            hl.bind("XF86AudioMicMute",      hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"), mediaOpts)
            hl.bind("XF86MonBrightnessUp",   hl.dsp.exec_cmd("brightnessctl s 10%+"), mediaOpts)
            hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("brightnessctl s 10%-"), mediaOpts)
          '';
        };

        # The ONLY hypridle definition now (previously also enabled system-wide
        # with empty settings, which overrode this one).
        services.hypridle = {
          enable = true;
          settings = {
            general = {
              lock_cmd = "pidof hyprlock || hyprlock";
              before_sleep_cmd = "loginctl lock-session";
              after_sleep_cmd = "hyprctl dispatch dpms on";
            };

            listener = [
              {
                # hyprmon: input-idle marker for activity tracking (180 s = same
                # convention as ActivityWatch/awatcher). Note: browsers hold an
                # idle-inhibit during video playback, so this listener stays
                # quiet while watching — media time is counted by hyprmon's MPRIS
                # sensor instead. Lock state is polled by hyprmon (LockedHint).
                timeout = 180;
                on-timeout = "hyprmon idle";
                on-resume = "hyprmon active";
              }
              {
                timeout = 150; # 2.5 min
                on-timeout = "brightnessctl -s set 10";
                on-resume = "brightnessctl -r";
              }
              {
                timeout = 150; # 2.5 min
                on-timeout = "brightnessctl -sd rgb:kbd_backlight set 0";
                on-resume = "brightnessctl -rd rgb:kbd_backlight";
              }
              {
                timeout = 300; # 5 min (zámek musí přijít před vypnutím displeje)
                on-timeout = "loginctl lock-session";
              }
              {
                timeout = 330; # 5.5 min (vypnutí displeje s bezpečným odstupem od zámku)
                on-timeout = "hyprctl dispatch dpms off";
                on-resume = "hyprctl dispatch dpms on";
              }
              {
                timeout = 1200; # 20 min (skutečný limit pro suspend)
                on-timeout = "systemctl suspend";
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

              # all these options are taken from hyprland, see https://wiki.hypr.land/Configuring/Variables/#blur for explanations
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
                dots_size = "0.33";
                dots_spacing = "0.15";
                dots_center = false;
                dots_rounding = -1;
                outer_color = "rgb(161, 189, 206)";
                inner_color = "rgba(200, 200, 200, 0.1)";
                font_color = "rgb(10, 10, 10)";
                fade_on_empty = true;
                fade_timeout = 1000;
                placeholder_text = "<i>Input Password...</i>";
                hide_input = false;
                rounding = 10;
                check_color = "rgba(204, 136, 34, 0.1)";
                fail_color = "rgb(204, 34, 34)";
                fail_text = "<i>$FAIL <b>($ATTEMPTS)</b></i>";
                fail_timeout = 2000;
                fail_transition = 300;
                capslock_color = -1;
                numlock_color = -1;
                bothlock_color = -1;
                invert_numlock = false;
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
    };
}
