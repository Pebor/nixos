# greetd + tuigreet login manager.
#
# Wayland sessions are discovered automatically: compositor/DE modules register
# themselves in `services.displayManager.sessionPackages` when enabled
# (programs.hyprland / niri / umbriel / mango, services.desktopManager.cosmic,
# ...). greetd's own NixOS module enables `services.displayManager`, which
# aggregates them into `services.displayManager.sessionData.desktops`, so
# tuigreet can just be pointed at that directory. Enabling a compositor on a
# host is therefore all that is needed for it to show up at login.
{
  flake.modules.nixos.greetd = { config, pkgs, ... }:
    let
      tuigreetExe = "${pkgs.tuigreet}/bin/tuigreet";
      sessions = "${config.services.displayManager.sessionData.desktops}/share/wayland-sessions";
    in
    {
      services.greetd = {
        enable = true;
        settings = {
          default_session = {
            command = "${tuigreetExe} --time --remember --remember-session --sessions ${sessions}";
            user = "greeter";
          };
        };
      };

      environment.systemPackages = with pkgs; [
        tuigreet
      ];

      # this is a life saver.
      # literally no documentation about this anywhere.
      # might be good to write about this...
      # https://www.reddit.com/r/NixOS/comments/u0cdpi/tuigreet_with_xmonad_how/
      systemd.services.greetd.serviceConfig = {
        Type = "idle";
        StandardInput = "tty";
        StandardOutput = "tty";
        StandardError = "journal"; # Without this errors will spam on screen
        # Without these bootlogs will spam on screen
        TTYReset = true;
        TTYVHangup = true;
        TTYVTDisallocate = true;
      };
    };
}
