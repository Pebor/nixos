# console-guard — a closed lid (or a forgotten console login) must never leave
# a logged-in shell for whoever walks past the machine.
#
# Why: the t490s lives in a shared dorm room. Until 2026-10-28 tty1
# auto-logged in as `server` (wheel + passwordless sudo), so opening the lid
# handed anyone a root-capable shell without a password. The autologin is gone
# (see hosts/t490s-server.nix); this module covers the other half — a session
# that was legitimately logged in otherwise stays open for as long as the box
# is up (measured 2026-10-28: one tty1 session, 2 days idle, LockedHint=no).
#
# Every minute, for LOCAL seat sessions only (Seat=seat0, Remote=no — never the
# agent's SSH session or container sessions): terminate when the lid is closed
# or the session has been idle past the limit. The tty then falls back to
# `login:` and needs the account password.
{ ... }:
{
  flake.modules.nixos.console-guard = { pkgs, ... }:
    let
      script = pkgs.writeScriptBin "console-guard" ''
        #!${pkgs.runtimeShell}
        ${builtins.readFile ./console-guard.sh}
      '';
    in
    {
      systemd.services.console-guard = {
        description = "Terminate an idle or lid-closed local console session";
        # A plain `writeScriptBin` script inherits systemd's minimal PATH, where
        # awk/loginctl/date do not exist — the first rollout died on
        # "awk: command not found" and silently no-oped. Declare the tools.
        path = with pkgs; [ bash coreutils systemd gawk gnugrep ];
        serviceConfig = {
          Type = "oneshot";
          User = "root";
          ExecStart = "${script}/bin/console-guard";
          Environment = [ "CONSOLE_IDLE_SECONDS=1800" ];
          TimeoutStartSec = "30";
        };
      };

      systemd.timers.console-guard = {
        description = "Console guard, every minute";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "1min";
          OnUnitActiveSec = "1min";
          AccuracySec = "10s";
          Unit = "console-guard.service";
        };
      };
    };
}
