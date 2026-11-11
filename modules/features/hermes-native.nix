# Hermes Agent as a native host service (cutover 2026-11-11).
#
# Topology: the agent process (gateway + dashboard + cron + MCP) runs here as
# `server` under systemd; every terminal / file / execute_code call is executed
# inside the nix-built `hermes-sandbox` image (`terminal.backend = "docker"`),
# which is disposable while the state dir is not.
#
# Why not the upstream NixOS module: it owns config.yaml (blocking
# `hermes config set` and dashboard edits) and seals the Python env, so
# `hermes pm install --extra` (piper TTS, whisper) cannot work. Here the
# install is the official git/uv one at /var/lib/hermes-native and Nix only
# owns the service definition.
{ pkgs, ... }:
{
  flake.modules.nixos.hermes-native = { pkgs, ... }: {
    systemd.services.hermes-native = {
      description = "Hermes Agent gateway (native install, docker sandbox for shell)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "docker.service" ];
      wants = [ "network-online.target" ];
      requires = [ "docker.service" ];
      environment = {
        HOME = "/home/server";
        HERMES_HOME = "/var/lib/hermes";
        HERMES_DASHBOARD = "1";
        PATH = "/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin";
      };
      serviceConfig = {
        User = "server";
        Group = "users";
        Type = "exec";
        ExecStart = "/var/lib/hermes-native/hermes-agent/.hermes/bin/hermes gateway run";
        Restart = "always";
        RestartSec = 5;
        TimeoutStopSec = 30;
        KillMode = "mixed";
      };
    };

    # The dashboard is a separate process (the container's s6 started it too);
    # `gateway run` never binds it itself.
    systemd.services.hermes-dashboard = {
      description = "Hermes Agent dashboard (http://127.0.0.1:9119)";
      wantedBy = [ "multi-user.target" ];
      after = [ "hermes-native.service" ];
      environment = {
        HOME = "/home/server";
        HERMES_HOME = "/var/lib/hermes";
        PATH = "/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin";
      };
      serviceConfig = {
        User = "server";
        Group = "users";
        Type = "exec";
        ExecStart = "/var/lib/hermes-native/hermes-agent/.hermes/bin/hermes dashboard --host 127.0.0.1 --port 9119";
        Restart = "always";
        RestartSec = 5;
      };
    };
  };
}
