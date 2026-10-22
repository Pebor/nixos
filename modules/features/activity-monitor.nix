# hyprmon — personal activity collector (windows/media/idle/WiFi/battery),
# event-driven off Hyprland's socket2 and censored at write time.
#
# Code, tests and docs: resources/hyprmon/ (see its README.md).
# Reports: `hyprmon-report --week YYYY-MM-DD` -> report.html + aggregates.json.
{ ... }:
{
  flake.modules.homeManager.activity-monitor = { pkgs, lib, ... }:
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
      # NOTE: the daemon reads ~/.config/hyprmon/hyprmon.toml (default_config_path).
      xdg.configFile."hyprmon/hyprmon.toml".source = ../../resources/hyprmon/config.toml;

      # Companion browser extension (active-tab -> channel/URL stats).
      # Load it unpacked from here in Zen/Helium. See resources/hyprmon/README.md.
      home.file.".local/share/hyprmon-extension".source = ../../resources/hyprmon/extension;

      # The store dir must exist before the sandboxed service starts:
      # ProtectHome=read-only means the daemon cannot create it itself.
      home.activation.hyprmonStore = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        install -d -m 0700 "$HOME/.local/share/hyprmon"
        chmod 0700 "$HOME/.local/share/hyprmon"
      '';

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
          # Hardened: the collector needs the Hyprland event socket (AF_UNIX in %t),
          # D-Bus (AF_UNIX), reads of /proc + /sys (process context), and a
          # loopback listener for browser tab reports.
          # The '-' prefix makes systemd tolerate a missing path instead of
          # failing the whole namespace with 226/NAMESPACE.
          ProtectSystem = "strict";
          ProtectHome = "read-only";
          ReadWritePaths = [ "-%h/.local/share/hyprmon" "%t" ];
          # AF_UNIX for Hyprland socket + D-Bus; AF_INET/AF_INET6 for the
          # loopback browser-tab URL ingest listener ([url_source]).
          RestrictAddressFamilies = "AF_UNIX AF_INET AF_INET6";
          NoNewPrivileges = true;
        };
        Install.WantedBy = [ "graphical-session.target" ];
      };
    };
}
