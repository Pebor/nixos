# hermes-status — one JSON endpoint with what Hermes is doing right now,
# for the desktop apps (agent-watch). Bound to the tailnet only.
{ ... }:
{
  flake.modules.nixos.hermes-status = { pkgs, ... }: {
    systemd.services.hermes-status = {
      description = "Hermes status JSON for the desktop apps";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = [ pkgs.python3 ];
      environment = {
        HERMES_DATA = "/var/lib/hermes";
        HERMES_STATUS_BIND = "100.103.136.50";
        HERMES_STATUS_PORT = "8099";
      };
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${./hermes-status.py}";
        Restart = "always";
        RestartSec = 3;
        User = "server";
        Group = "users";
      };
    };

    # reachable over the tailnet, nothing else
    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 8099 ];
  };
}
