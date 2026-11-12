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
      # "bash not found on PATH" without them. openssh: plugins (desktop-notify) ssh to the T14 — in the container era
      # ssh came from the image. rsync: the tasks-app web cron rsyncs the bundle
      # into ~/tasks-web/site. util-linux + glibc.bin: the Kotlin toolchain's
      # launcher calls `linux64` and `getconf`; without them the nightly web
      # build died with "linux64: command not found".
      path = [ pkgs.docker pkgs.bash pkgs.python3 pkgs.coreutils pkgs.git pkgs.curl
               pkgs.openssh pkgs.rsync pkgs.util-linux pkgs.glibc.bin ];
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "docker.service" ];
      wants = [ "network-online.target" ];
      requires = [ "docker.service" ];
      environment = {
        HOME = "/home/server";
        HERMES_HOME = "/var/lib/hermes";
        HERMES_DASHBOARD = "1";
        # The bundled python-build-standalone has no compiled-in cafile and NixOS
        # keeps no openssl-hashed /etc/ssl/certs, so HTTPS from cron scripts died
        # with CERTIFICATE_VERIFY_FAILED (topic sweep deletes, fin tidy).
        SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
        # Browser screenshots must land where the sandbox can read them: file and
        # vision tools resolve local paths INSIDE hermes-sandbox, and the harness
        # default ($XDG_CONFIG_HOME/browser-harness/tmp = host /tmp) is invisible
        # there. /home/server is mounted rw in both, so both sides see the shot.
        BH_TMP_DIR = "/home/server/.cache/browser-harness/tmp";
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

    # Chromium paints text only when the system has fonts. The headless server
    # had exactly one (fc-list), so every browser_exec screenshot came back
    # blank apart from CSS box backgrounds — half-painted pages, no glyphs.
    fonts.enableDefaultPackages = true;
    fonts.fontconfig.enable = true;
    fonts.packages = with pkgs; [ dejavu_fonts liberation_ttf noto-fonts ];

    # The dashboard is a separate process (the container's s6 started it too);
    # `gateway run` never binds it itself.
    # Docker bridges may reach the dashboard port on the host: Caddy lives in a
    # container and proxies ai.dash.pebor.me to host.docker.internal:9119.
    # The host runs the iptables firewall backend, where the declarative
    # `extraInputRules` option does NOT exist (it is nftables-only and is
    # silently ignored) — so the rule goes in as an iptables command. Caddy
    # lives in a container and proxies ai.dash.pebor.me to the host's 9119.
    # The edge containers (demo-bridge, inbox-push) talk to the gateway API on
    # 8642 the same way — before the move they reached the `hermes` container by
    # service name; there is no such container now, so they go through the
    # docker gateway and need the port open from the bridge networks.
    networking.firewall.extraCommands = ''
      iptables -A nixos-fw -i br-+ -p tcp --dport 9119 -j nixos-fw-accept
      iptables -A nixos-fw -i docker0 -p tcp --dport 9119 -j nixos-fw-accept
      iptables -A nixos-fw -i br-+ -p tcp --dport 8642 -j nixos-fw-accept
      iptables -A nixos-fw -i docker0 -p tcp --dport 8642 -j nixos-fw-accept
      # 8644 = the webhook port the tasks-api container posts card changes to.
      # Without it the kanban wake never fired: a new card sat in Backlog and no
      # agent session started (TASKS_HOOK_URL also still named the old `hermes`
      # container, fixed in ~/tasks-api/.env).
      iptables -A nixos-fw -i br-+ -p tcp --dport 8644 -j nixos-fw-accept
      iptables -A nixos-fw -i docker0 -p tcp --dport 8644 -j nixos-fw-accept
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
