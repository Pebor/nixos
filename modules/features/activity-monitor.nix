# hyprmon — personal activity collector (windows/media/idle/WiFi/battery),
# event-driven off Hyprland's socket2 and censored at write time.
#
# Code, tests and docs: resources/hyprmon/ (see its README.md).
# Reports: `hyprmon-report --week YYYY-MM-DD` -> report.html + aggregates.json.
{ ... }:
{
  flake.modules.homeManager.activity-monitor = { pkgs, ... }:
    let
      py = "${pkgs.python3}/bin/python3";
      # PATH export: the daemon shells out to hyprctl/busctl/loginctl/nmcli.
      pathFix = ''
        export PATH=/run/current-system/sw/bin:$HOME/.nix-profile/bin:/etc/profiles/per-user/$(id -un)/bin:$PATH
      '';
      hyprmon = pkgs.writeShellScriptBin "hyprmon" ''
        ${pathFix}exec ${py} ${../../resources/hyprmon/hyprmon.py} "$@"
      '';
      hyprmon-report = pkgs.writeShellScriptBin "hyprmon-report" ''
        ${pathFix}exec ${py} ${../../resources/hyprmon/hyprmon-report.py} "$@"
      '';
    in
    {
      home.packages = [ hyprmon hyprmon-report ];

      # Config lives in the repo; edit it here and `hmswitch`.
      xdg.configFile."hyprmon/config.toml".source = ../../resources/hyprmon/config.toml;

      systemd.user.services.hyprmon = {
        Unit = {
          Description = "hyprmon - Hyprland activity collector (censored at write time)";
          After = [ "graphical-session.target" ];
        };
        Service = {
          Type = "simple";
          ExecStart = "${hyprmon}/bin/hyprmon run";
          Restart = "always";
          RestartSec = "3";
          # Hardened: the collector only needs the Hyprland event socket
          # (AF_UNIX in %t), D-Bus (AF_UNIX) and reads of /proc + /sys.
          ProtectSystem = "strict";
          ProtectHome = "read-only";
          ReadWritePaths = [ "%h/.local/share/hyprmon" "%t" ];
          RestrictAddressFamilies = "AF_UNIX";
          NoNewPrivileges = true;
        };
        Install.WantedBy = [ "graphical-session.target" ];
      };
    };
}
