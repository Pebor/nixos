# thought-sink — thoughts from pebor.me arrive on this machine.
#
# Holds one SSE connection to the site's API: thoughts are pushed over it (never
# polled) and the connection doubles as the public "laptop online" signal.
# The token lives in /var/lib/hermes/thought-sink.env (mode 600), never in the
# nix store.
{ ... }:
{
  flake.modules.nixos.thought-sink = { pkgs, ... }: {
    systemd.services.thought-sink = {
      description = "pebor.me thought box → this machine";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # the desktop toast shells out to ssh; systemd default PATH has neither
      path = [ pkgs.openssh ];
      environment = {
        THOUGHT_API = "https://pebor.me";
        THOUGHT_STATE_DIR = "/var/lib/hermes/var/thought-sink";
      };
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${./thought-sink.py}";
        EnvironmentFile = "-/var/lib/hermes/thought-sink.env";
        Restart = "always";
        RestartSec = 5;
        User = "server";
        Group = "users";
        StateDirectory = "hermes/var/thought-sink";
        StateDirectoryMode = "0750";
      };
    };
  };
}
