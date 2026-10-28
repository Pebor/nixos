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
      # The report writes a single-file dashboard from a template it looks up as
      # `<script dir>/dashboard.html`, so both files must live in one directory:
      # interpolating the .py alone would put it in /nix/store with no template.
      reportDir = pkgs.runCommand "hyprmon-report-src" { } ''
        mkdir -p $out
        cp ${../../resources/hyprmon/hyprmon-report.py} $out/hyprmon-report.py
        cp ${../../resources/hyprmon/dashboard.html} $out/dashboard.html
      '';
      hyprmon-report = pkgs.writeShellScriptBin "hyprmon-report" ''
        ${pathFix}exec ${py} ${reportDir}/hyprmon-report.py "$@"
      '';
      # Unsigned XPI of the companion extension. Zen 1.23 honours
      # xpinstall.signatures.required=false, so a profile-local XPI loads on
      # every start instead of needing about:debugging after each restart.
      hyprmonExtension = pkgs.runCommand "hyprmon-extension.xpi" {
        nativeBuildInputs = [ pkgs.zip ];
      } ''
        mkdir ext
        cp -r ${../../resources/hyprmon/extension}/. ext/
        (cd ext && zip -q -X -r "$out" .)
      '';
    in
    {
      home.packages = [ hyprmon hyprmon-report ];

      # Config lives in the repo; edit it here and `hmswitch`.
      # NOTE: the daemon reads ~/.config/hyprmon/hyprmon.toml (default_config_path).
      xdg.configFile."hyprmon/hyprmon.toml".source = ../../resources/hyprmon/config.toml;

      # Companion browser extension (active-tab -> channel/URL stats).
      # Unpacked source kept for dev / manual loading (web-ext run).
      home.file.".local/share/hyprmon-extension".source = ../../resources/hyprmon/extension;

      # Install the extension permanently into every Zen profile it finds.
      # Zen profile dirs have random names, so they are read from profiles.ini
      # instead of being hard-coded. Two prefs go into the profile's user.js:
      # signatures off (unsigned add-on) and autoDisableScopes=0 (otherwise a
      # sideloaded XPI is registered but left disabled).
      home.activation.hyprmonZenExtension = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        zenConfig="$HOME/.config/zen"
        install_profile() {
          prof="$1"
          [ -d "$prof" ] || return 1
          install -d -m 0700 "$prof/extensions"
          install -m 0644 ${hyprmonExtension} "$prof/extensions/hyprmon@local.xpi"
          if ! grep -qF '# >>> hyprmon extension' "$prof/user.js" 2>/dev/null; then
            {
              [ -f "$prof/user.js" ] && cat "$prof/user.js"
              echo '# >>> hyprmon extension (managed by home-manager)'
              echo 'user_pref("xpinstall.signatures.required", false);'
              echo 'user_pref("extensions.autoDisableScopes", 0);'
              echo '# <<< hyprmon extension'
            } > "$prof/.user.js.new"
            mv "$prof/.user.js.new" "$prof/user.js"
          fi
          echo "hyprmon: extension installed into $prof" >&2
          return 0
        }
        installed=0
        if [ -f "$zenConfig/profiles.ini" ]; then
          # Read the ini line by line instead of feeding sed output through a
          # heredoc: `IFS= read` keeps leading whitespace, and a profile named
          # "p4q16twc.Default Profile" then looked like a missing directory, so
          # the extension was silently never installed.
          while IFS= read -r line; do
            case "$line" in
              Path=*) ;;
              *) continue ;;
            esac
            rel="''${line#Path=}"
            rel="$(printf '%s' "$rel" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            [ -n "$rel" ] || continue
            case "$rel" in
              /*) prof="$rel" ;;
              *) prof="$zenConfig/$rel" ;;
            esac
            if install_profile "$prof"; then installed=$((installed + 1)); fi
          done < "$zenConfig/profiles.ini"
        fi
        # Fallback: a profile that profiles.ini does not list (new "profile
        # groups" layout) is still found by its prefs.js.
        if [ "$installed" -eq 0 ] && [ -d "$zenConfig" ]; then
          for prof in "$zenConfig"/*/; do
            prof="''${prof%/}"
            [ -f "$prof/prefs.js" ] || continue
            if install_profile "$prof"; then installed=$((installed + 1)); fi
          done
        fi
        if [ "$installed" -eq 0 ]; then
          echo "hyprmon: no Zen profile found under $zenConfig - extension NOT installed" >&2
        fi
      '';

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
