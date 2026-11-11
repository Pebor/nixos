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
      # docker: spawn the sandbox. bash/python3/coreutils/git/curl: `no_agent`
      # cron scripts are executed by the gateway and die with
      # "bash not found on PATH" without them.
      path = [ pkgs.docker pkgs.bash pkgs.python3 pkgs.coreutils pkgs.git pkgs.curl ];
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "docker.service" ];
      wants = [ "network-online.target" ];
      requires = [ "docker.service" ];
      environment = {
        HOME = "/home/server";
        HERMES_HOME = "/var/lib/hermes";
        HERMES_DASHBOARD = "1";
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
    # Docker bridges may reach the dashboard port on the host: Caddy lives in a
    # container and proxies ai.dash.pebor.me to host.docker.internal:9119.
    # The host runs the iptables firewall backend, where the declarative
    # `extraInputRules` option does NOT exist (it is nftables-only and is
    # silently ignored) — so the rule goes in as an iptables command. Caddy
    # lives in a container and proxies ai.dash.pebor.me to the host's 9119.
    networking.firewall.extraCommands = ''
      iptables -A nixos-fw -i br-+ -p tcp --dport 9119 -j nixos-fw-accept
      iptables -A nixos-fw -i docker0 -p tcp --dport 9119 -j nixos-fw-accept
    '';

    systemd.services.hermes-dashboard = {
      description = "Hermes Agent dashboard (http://127.0.0.1:9119)";
      wantedBy = [ "multi-user.target" ];
      after = [ "hermes-native.service" ];
      environment = {
        HOME = "/home/server";
        HERMES_HOME = "/var/lib/hermes";
      };
      serviceConfig = {
        User = "server";
        Group = "users";
        Type = "exec";
        # 0.0.0.0 because the dashboard is proxied by the edge Caddy *container*
        # (via host.docker.internal) — the firewall rule below keeps it off the
        # LAN; Caddy's basic-auth gate is the perimeter, as before.
        ExecStart = "/var/lib/hermes-native/hermes-agent/.hermes/bin/hermes dashboard --host 0.0.0.0 --port 9119";
        Restart = "always";
        RestartSec = 5;
      };
    };
  };
}
