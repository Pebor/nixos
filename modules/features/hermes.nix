# Hermes agent (t490s-server): Nous Research's agent in Docker — gateway
# (Telegram/…), web dashboard on :9119, a shared ~/nixos tree, and an SSH
# back-channel to the host for nixos-rebuild.
#
# Secrets live ONLY in /var/lib/hermes/.env (chmod 600) — never in the repo
# or the nix store. hermes-seed refuses to start the container without them
# and seeds the non-secret files (config, SOUL, git/ssh setup) on first run.
# One-time bootstrap: see README "Hermes agent".
#
# `hermes` on the server talks to him via docker exec; `hermes-client` (Home
# Manager, imported by the other hosts) wraps the same call over SSH so every
# machine can reach him with the same command. Bare `hermes` launches the Ink
# TUI (display.interface: tui). zellij is never involved: Pebor opens it
# himself and runs `hermes` in a pane for multitasking.
{ inputs, ... }:
{
  flake.modules.nixos.hermes =
    { config, pkgs, lib, ... }:
    let
      stateDir = "/var/lib/hermes";

      # Seeded to ${stateDir}/config.yaml if missing; afterwards hermes owns
      # the file (edit via `hermes config set` or the dashboard).
      configFile = pkgs.writeText "hermes-config.yaml" ''
        model:
          provider: opencode-go
          default: mimo-v2.6-pro

        display:
          interface: tui

        approvals:
          mode: smart
          smart_policy: |
            Always ESCALATE commands that: run sudo, nixos-rebuild or nh;
            start/stop/restart system services; reboot or shut down the
            machine; git push or rewrite history; or modify anything outside
            /home/server/nixos. Plain edits under /home/server/nixos and
            read-only inspection may run without asking. Before a rebuild,
            say in one sentence what it will change.
          deny:
            - "git push*--force*"
      '';

      soulFile = pkgs.writeText "hermes-SOUL.md" ''
        # hermes

        You are hermes, an agent living in Docker on the t490s-server — a
        headless laptop running the NixOS config of this very repository.

        ## Workspace
        - `/home/server/nixos` — the flake that configures THIS machine. It is
          the host's `~/nixos` mounted at the same path: edits are live on the
          host immediately.
        - Host access: `ssh server@host.docker.internal` (key auth; passwordless
          sudo). The host sees the same tree at `~/nixos`.

        ## Rebuild workflow
        1. Edit files under `/home/server/nixos`
           (server config: `modules/hosts/t490s-server.nix`).
        2. Test: `ssh server@host.docker.internal 'sudo nixos-rebuild switch --flake ~/nixos#t490s-server'`
           (rollback if it goes wrong: `sudo nixos-rebuild --rollback`).
        3. Only when it works: `git -C /home/server/nixos add -A && git -C /home/server/nixos commit && git -C /home/server/nixos push`

        ## Rules of engagement
        Three tiers of autonomy:
        - Inside the container: never ask — just do it and report.
        - t490s host, regular ops (nixos rebuilds, service restarts,
          reboots, flake commit/push): no approval needed — announce in
          chat what you're about to do first, then do it.
        - Anything outside t490s (other machines, external services,
          effects beyond this host): ask first and wait for approval.
          Approvals are per-request, never standing — re-ask unless he
          explicitly granted it.
        - Never force-push. Never read or exfiltrate secrets (`/var/lib/hermes/.env`,
          ssh keys, tokens).
        - Prefer small, reviewable changes and explain them in plain words.
      '';

      gitconfig = pkgs.writeText "hermes-gitconfig" ''
        [user]
        	name = hermes
        	email = hermes@t490s
        [credential "https://github.com"]
        	username = x-access-token
        	helper = "!f() { echo password=$GH_TOKEN; }; f"
      '';

      # Inside the container the state dir is /opt/data (HERMES_HOME).
      sshConfig = pkgs.writeText "hermes-ssh-config" ''
        Host host.docker.internal
          User server
          IdentityFile /opt/data/home/.ssh/id_ed25519
          UserKnownHostsFile /opt/data/home/.ssh/known_hosts
          StrictHostKeyChecking accept-new
      '';

      hermes = pkgs.writeShellApplication {
        name = "hermes";
        runtimeInputs = [ config.virtualisation.docker.package ];
        text = ''
          if [ -t 0 ]; then
            exec docker exec -it hermes hermes "$@"
          else
            exec docker exec -i hermes hermes "$@"
          fi
        '';
      };

    in
    {
      virtualisation.oci-containers.backend = "docker";

      virtualisation.oci-containers.containers.hermes = {
        image = "nousresearch/hermes-agent:latest";
        # NOT "gateway run": image >= 0.22 supervises the gateway itself —
        # cont-init.d/02-reconcile-profiles auto-starts it as an s6 service
        # (desired_state=running persists in ${stateDir}/gateway_state.json).
        # A `gateway run` CMD then finds that gateway already running, exits 0,
        # s6 takes the whole container down and systemd restarts it — the
        # 2026-10-19 restart loop. The CMD only has to stay alive.
        cmd = [ "sleep" "infinity" ];
        # Localhost only: the sole way in is `tailscale serve` (tailnet) on
        # :8444. Never publish this port publicly — tailnet + dashboard basic
        # auth are the perimeter (see the NOTE in the hermes-seed check below).
        ports = [ "127.0.0.1:9119:9119" ];
        volumes = [
          "${stateDir}:/opt/data"
          "/home/server/nixos:/home/server/nixos"
        ];
        environment = {
          HERMES_DASHBOARD = "1";
        };
        environmentFiles = [
          "/run/hermes/env"
          "${stateDir}/.env"
        ];
        extraOptions = [
          "--memory=8g"
          "--cpus=6"
          "--add-host=host.docker.internal:host-gateway"
        ];
      };

      environment.systemPackages = [ hermes ];

      # The generated unit is Restart=on-failure; a gateway is meant to be up.
      systemd.services.docker-hermes.serviceConfig.Restart = lib.mkForce "always";

      # Requisite (not Requires) on the seed: still fail-closed at boot —
      # the container refuses to start while hermes-seed is inactive (its
      # secrets check refuses), but a later hermes-seed restart no longer
      # cascades into stopping the running container. Requires= did exactly
      # that: every rebuild touching the seed script bounced the container
      # and killed the agent's live session.
      systemd.services.docker-hermes.unitConfig.Requisite = [ "hermes-seed.service" ];

      systemd.services.hermes-seed = {
        description = "Provision hermes state, config and host access";
        before = [ "docker-hermes.service" ];
        # Started at boot on its own (NOT pulled in by docker-hermes' old
        # Requires= — see the Requisite note below).
        wantedBy = [ "multi-user.target" ];
        path = [ pkgs.openssh ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -eu
          install -d -m 0750 ${stateDir} /run/hermes ${stateDir}/home/.ssh

          # Run the container's hermes user as `server` so writes to the
          # mounted ~/nixos land with host ownership (git stays happy).
          uid=$(id -u server)
          gid=$(id -g server)
          printf 'HERMES_UID=%s\nHERMES_GID=%s\n' "$uid" "$gid" > /run/hermes/env

          # Seed-if-missing: hermes owns these files after first boot.
          [ -f ${stateDir}/config.yaml ] || install -m 0600 ${configFile} ${stateDir}/config.yaml
          [ -f ${stateDir}/SOUL.md ] || install -m 0600 ${soulFile} ${stateDir}/SOUL.md
          [ -f ${stateDir}/home/.gitconfig ] || install -m 0600 ${gitconfig} ${stateDir}/home/.gitconfig

          # nix-managed (overwritten each boot).
          install -m 0600 ${sshConfig} ${stateDir}/home/.ssh/config

          if [ ! -f ${stateDir}/home/.ssh/id_ed25519 ]; then
            ssh-keygen -q -t ed25519 -N "" -C "hermes@t490s" -f ${stateDir}/home/.ssh/id_ed25519
          fi

          # This unit runs as root, so `install`/`ssh-keygen` above create
          # root-owned files the container's hermes user cannot read (SOUL.md
          # breaks `hermes doctor` and silently drops the persona). Hand the
          # seeded state to the container user on every boot — unconditional,
          # so already-broken files self-heal.
          chown "$uid":"$gid" \
            ${stateDir}/config.yaml ${stateDir}/SOUL.md ${stateDir}/home/.gitconfig \
            ${stateDir}/home/.ssh/config ${stateDir}/home/.ssh/id_ed25519 ${stateDir}/home/.ssh/id_ed25519.pub

          # Host access for rebuilds: hermes logs in as `server` (passwordless sudo).
          install -d -m 0700 -o server -g "$gid" /home/server/.ssh
          touch /home/server/.ssh/authorized_keys
          chown server:"$gid" /home/server/.ssh/authorized_keys
          chmod 0600 /home/server/.ssh/authorized_keys
          pub=$(cat ${stateDir}/home/.ssh/id_ed25519.pub)
          grep -qF "$pub" /home/server/.ssh/authorized_keys || echo "$pub" >> /home/server/.ssh/authorized_keys

          # Secrets: refuse to start without them. The dashboard basic auth is
          # NOT optional: image >= 0.22 refuses to bind the dashboard to 0.0.0.0
          # with no auth provider, and a loopback bind inside the container is
          # unreachable through docker port forwarding — so without these vars
          # the dashboard never comes up at all (observed 2026-10-19). Host
          # publish is 127.0.0.1-only behind `tailscale serve` (tailnet), so
          # the password is a second layer, not the perimeter.
          envFile=${stateDir}/.env
          if [ ! -f "$envFile" ]; then
            echo "hermes-seed: $envFile is missing — create it first (README, 'Hermes agent'):" >&2
            echo "  sudo install -d -m 750 ${stateDir}" >&2
            echo "  sudo tee ${stateDir}/.env >/dev/null <<'EOF'  # then chmod 600" >&2
            echo "  OPENCODE_GO_API_KEY=...          # opencode.ai console" >&2
            echo "  HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin" >&2
            echo "  HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=..." >&2
            echo "  HERMES_DASHBOARD_BASIC_AUTH_SECRET=\$(openssl rand -base64 32)" >&2
            echo "  EOF" >&2
            exit 1
          fi
          for v in \
            OPENCODE_GO_API_KEY \
            HERMES_DASHBOARD_BASIC_AUTH_USERNAME \
            HERMES_DASHBOARD_BASIC_AUTH_PASSWORD \
            HERMES_DASHBOARD_BASIC_AUTH_SECRET
          do
            grep -q "^$v=." "$envFile" || {
              echo "hermes-seed: $v is missing or empty in $envFile" >&2
              exit 1
            }
          done
          grep -q '^GH_TOKEN=.' "$envFile" \
            || echo "hermes-seed: warning: GH_TOKEN missing — git push will fail" >&2
        '';
      };
    };

  flake.modules.homeManager.hermes-client =
    { pkgs, ... }:
    let
      hermes = pkgs.writeShellApplication {
        name = "hermes";
        runtimeInputs = [ pkgs.openssh ];
        text = ''
          # Same CLI as on the t490s-server, reached over SSH. Bare `hermes`
          # launches the TUI there (display.interface: tui); zellij is never
          # started implicitly. No args = TUI, args = plain CLI passthrough.
          dest="''${HERMES_SSH_DEST:-server@t490s}"
          if [ -t 0 ]; then
            exec ssh -t "$dest" hermes "$@"
          else
            exec ssh "$dest" hermes "$@"
          fi
        '';
      };
    in
    {
      home.packages = [ hermes ];
    };
}
