# Hermes Agent as a native host service (cutover 2026-11-11).
#
# Topology: the agent process (gateway + dashboard + cron + MCP) runs here as
# `server` under systemd; every terminal / file / execute_code call is executed
# inside the nix-built `hermes-sandbox` image (`terminal.backend = "docker"`),
# which is disposable while the state dir is not.
#
# Why not the upstream NixOS module: it owns config.yaml (blocking
# `hermes config set` and dashboard edits). Here the binary is pinned from the
# upstream flake at v0.23.1; Nix owns the service definition, config stays
# mutable in /var/lib/hermes.
{ inputs, pkgs, ... }:
{
  flake.modules.nixos.hermes-native = { pkgs, ... }:
    let
      # One pin for the service, the dashboard and the CLI wrapper: see lib/hermes-pin.nix
      hermesAgent = import ../../lib/hermes-pin.nix { inherit inputs pkgs; };
      # Host-side helper used from inside the sandbox. Nix-managed now: the old
      # ~/.local/bin copy was load-bearing but had no diff and no rollback.
      hermesHost = pkgs.writeShellScript "hermes-host" ''
        #!/bin/sh
        exec docker run --rm --pid=host --net=host \
          -v /:/host -v /run:/run -v /nix:/nix:ro -e HOME=/root \
          hermes-sandbox:latest /bin/sh -c '
            export PATH=/host/run/current-system/sw/bin:/host/usr/bin:/usr/bin:/bin
            cd /host
            if [ "$1" = rebuild ]; then
              exec ssh -i /host/var/lib/hermes/home/.ssh/id_ed25519 \
                -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o BatchMode=yes \
                server@127.0.0.1 \
                "cd /home/server/nixos && sudo -n nixos-rebuild switch --flake .#t490s-server"
            fi
            exec "$@"
          ' -- "$@"
      '';
    in {
    systemd.tmpfiles.rules = [
      "L+ /home/server/.local/bin/hermes-host - - - - ${hermesHost}"
      # Short-lived screenshots and scratch; long-lived images go to
      # /home/server/files/Documents/screenshots/ (filebrowser/cloud).
      "d /home/server/tmp 0755 server users 7d"
      "d /home/server/tmp/screenshots 0755 server users 7d"
      "d /home/server/tmp/scratch 0755 server users 7d"
    ];

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
               pkgs.openssh pkgs.rsync pkgs.util-linux pkgs.glibc.bin pkgs.android-tools ];
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "docker.service" ];
      wants = [ "network-online.target" "hermes-plugins-deploy.service" ];
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
        # Terminal/sandbox topology lives in config.yaml's `terminal:` block,
        # seeded by modules/features/hermes/default.nix. Do NOT duplicate it as
        # TERMINAL_DOCKER_* here: terminal_tool calls
        # apply_terminal_config_to_env(override=True) whenever config.yaml has a
        # terminal section, so the unit env is silently overwritten. That is how
        # the first activation looked green while the sandbox still ran as root.
        #
        # Contract in config.yaml: uid 1001, /var/lib/hermes rw, .env ro,
        # secrets.env masked, SSH key ro, --network=host, --group-add=131.
      };
      serviceConfig = {
        User = "server";
        Group = "users";
        Type = "exec";
        ExecStart = "${hermesAgent}/bin/hermes gateway run";
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

    systemd.services.hermes-plugins-deploy = {
      description = "Deploy Hermes plugins from the flake repo into HERMES_HOME";
      wantedBy = [ "multi-user.target" ];
      after = [ "hermes-seed.service" ];
      before = [ "hermes-native.service" ];
      path = [ pkgs.rsync pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "server";
        Group = "users";
      };
      script = ''
        install -d -m 0755 /var/lib/hermes/plugins
        rsync -a --delete --exclude '__pycache__' \
          /home/server/nixos/images/hermes/plugins/ /var/lib/hermes/plugins/
      '';
    };

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
        ExecStart = "${hermesAgent}/bin/hermes dashboard --host 0.0.0.0 --port 9119";
        Restart = "always";
        RestartSec = 5;
      };
    };
  };
}
