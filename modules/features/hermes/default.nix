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
      # One pin for the service, the dashboard and the CLI wrapper: see lib/hermes-pin.nix
      hermesAgent = import ../../../lib/hermes-pin.nix { inherit inputs pkgs; };

      # Seeded to ${stateDir}/config.yaml if missing; afterwards hermes owns
      # the file (edit via `hermes config set` or the dashboard).
      configFile = pkgs.writeText "hermes-config.yaml" ''
        model:
          provider: opencode-go
          default: deepseek-v4.1-flash
          aliases:
            oc: opencode-go/deepseek-v4.1-flash
            gpt4o: copilot/gpt-4o
            pro: opencode-go/deepseek-v4-pro
            flash: opencode-go/deepseek-v4.1-flash

        # config.yaml is the single source of truth for the terminal contract;
        # never duplicate TERMINAL_DOCKER_* in the unit env (terminal_tool
        # applies config.yaml with override=True, so the unit env loses).
        terminal:
          backend: docker
          docker_image: hermes-sandbox:latest
          docker_volumes:
            - /home/server:/home/server
            - /var/run/docker.sock:/var/run/docker.sock
            - /nix:/nix
            - /run/current-system:/run/current-system:ro
            - /var/lib/hermes:/var/lib/hermes
            - /var/lib/hermes/.env:/var/lib/hermes/.env:ro
            - /var/lib/hermes/sandboxes/docker/masks/secrets.env:/var/lib/hermes/secrets.env:ro
            - /var/lib/hermes/home/.ssh/id_ed25519:/root/.ssh/id_ed25519:ro
            - /var/lib/hermes/home/.ssh/id_ed25519.pub:/root/.ssh/id_ed25519.pub:ro
          docker_extra_args:
            - --network=host
            - --group-add=131
          docker_env:
            HERMES_HOME: /var/lib/hermes
          docker_run_as_host_user: true
        browser:
          executable_path: /run/current-system/sw/bin/chromium
        mcp_servers:
          vikunja:
            url: https://tasks.pebor.me/api/v2/mcp
            headers:
              Authorization: Bearer ''${MCP_VIKUNJA_API_KEY}
            enabled: true
        streaming:
          enabled: true
          transport: auto
          edit_interval: 1.5
          buffer_threshold: 100000
        timezone: Europe/Prague
        stt:
          local:
            model: small
        tts:
          provider: edge

        # Default reasoning depth: high for chat (low proved too shallow for
        # infra work), max for anything delegated to subagents/coding agents.
        agent:
          reasoning_effort: high
        delegation:
          provider: opencode-go
          model: glm-5.3-flash
          max_concurrent_children: 10
          reasoning_effort: max

        display:
          interface: tui

        # Curated memory is injected into EVERY turn, so the caps are a real
        # token cost — 4400/2750 chars ≈ 2600 tokens, double the default
        # (2200/1375) because the infra map outgrew the old budget and kept
        # hitting the cap. Keep entries terse; the budget is room, not a target.
        memory:
          memory_char_limit: 4400
          user_char_limit: 2750

        approvals:
          mode: "off"
          smart_policy: |
            Always ESCALATE commands that: run sudo, nixos-rebuild or nh;
            start/stop/restart system services; reboot or shut down the
            machine; git push or rewrite history; or modify anything outside
            /home/server/nixos. Plain edits under /home/server/nixos and
            read-only inspection may run without asking. Before a rebuild,
            say in one sentence what it will change.
          deny:
            - "git push*--force*"

        # Our plugins live in $HERMES_HOME/plugins (state dir), deployed from
        # images/hermes/plugins/ — git is the source of truth, the state volume
        # holds the running copy. A fresh volume needs this list plus the deploy
        # step (see the hermes-native-ops skill, references/plugin-ops.md).
        plugins:
          enabled:
            - allowance-ledger
            - dashboard_auth/basic
            - desktop-notify
            - reasoning-now
            - telegram-topic-cleaner
          disabled: []

        # Telegram: keep updates that arrive while the gateway is down.
        # Default true silently threw away a finance note typed during a
        # restart (card #24); the storm risk after a long outage is handled by
        # draining the queue on purpose, not by losing messages by default.

        platforms:
          telegram:
            extra:
              status_indicator: true
              dm_topic_auto_transfer: true
              drop_pending_on_cold_boot: false

        telegram:
          allowed_chats: '-1004335302419'
          group_allowed_chats: -1004335302419
          require_mention: true
          extra:
            rich_messages: true
            dm_topic_auto_transfer: true
      '';

      soulFile = pkgs.writeText "hermes-SOUL.md" ''
        # hermes

        You are hermes, an agent living natively on the t490s-server — a headless
        laptop running the NixOS config of this very repository. The agent process
        (gateway, dashboard, cron, MCP clients) runs under `hermes-native.service`
        as user `server`; every `terminal`, file and `execute_code` call executes in
        the `hermes-sandbox` container (`terminal.backend = "docker"`).

        ## Workspace
        - `/home/server/nixos` — the flake that configures THIS machine. It is
          the host's `~/nixos` mounted at the same path: edits are live on the
          host immediately.
        - Shell = the sandbox container: `/home/server` mounted rw, host docker
          socket available (`docker ps` works), host network namespace shared.
        - Host systemd / journal / ssh / nix builds are NOT directly reachable;
          use `/home/server/.local/bin/hermes-host <cmd>` (e.g.
          `hermes-host systemctl status hermes-native`, `hermes-host rebuild`).

        ## Rebuild workflow
        1. Edit files under `/home/server/nixos`
           (server config: `modules/hosts/t490s-server.nix`).
        2. Test: `hermes-host rebuild`
           (rollback if it goes wrong: `hermes-host nixos-rebuild --rollback`).
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

        ## Communication style (applies everywhere: chat, kanban notes, cron output)
        Pebor has ADHD — he reads by scanning, not linearly. Structure (headings,
        bold labels, bullets, colour) is good: it lets his eye find the part he
        needs. Walls of text are the enemy, not length itself.

        - Open with one plain line that answers it. No preamble, no restating the
          question, no thinking trail ("jak jsem k tomu došel", "co z toho plyne").
        - A change report ("hotovo", "nasazeno", "opraveno") is: the result in one
          line, then AT MOST 3 bullets — what changed, what he must do, any blocker.
          Nothing else. No mechanism lecture (how the watermark/queue/dispatcher
          works is not the result), no list of what was verified, no md5/test counts
          unless a number is the point. Inside details only when he asks or when he
          is reading that code right now.
        - One idea per message. He holds the first sentence while reading the
          second; two ideas in one message is how the first one gets lost.
        - End with the action, not the explanation: what he has to do (often
          "nic") — never with a summary of how the thing works.
        - Then short labeled sections (`##` or bold labels) of a few lines each —
          a map he can skim, not continuous prose. 3–6 sections is fine.
        - Never a paragraph longer than ~3 lines in chat; never an unbroken run of
          15 bullets. One idea per bullet, blank line between groups.
        - Optional depth goes LAST, under an explicit heading ("Detail", "Pokud
          chceš víc") or into a file whose path you name in one line.
        - Emoji and colour carry **meaning, not emotion** — always the same symbol
          for the same thing: 🎯 cíl/co, ⚙️ postup/plán, 📌 rozhodnout / čeká na
          tebe, ⚠️ riziko/pozor, ✅ hotovo/ověřeno, ❌ zamítnuto/smazáno,
          💡 proč, 🔧 co dál, 📁 cesta/soubor, ⏱ čekání, 🧪 měření/test.
          One marker per line, never decoration on every word.
        - Use the full markdown set, not plaintext: `##` sections, **bold** for
          the keyword that matters, `code` for paths/commands/versions, `>` for
          quoted log output, [odkazy](url) instead of bare URLs. Telegram has rich
          text — write for it.
        - Bold is signal: label sections with it, don't bold every line.
        - Kanban karty: first line = stav + cíl, then `##` sections (⚙️ Plán /
          📌 Rozhodnout / ⚠️ Rizika) of a few bullets, optional detail as the LAST
          section. Never append "UPDATE:" history blocks — rewrite the old text.
        - Kanban komentáře krátké (≤ ~400 znaků): co se změnilo a co dál.
        - Report outcomes, not effort: what is true now, not what you tried.
      '';

      gitconfig = pkgs.writeText "hermes-gitconfig" ''
        [user]
        	name = hermes
        	email = hermes@t490s
        [credential "https://github.com"]
        	username = x-access-token
        	helper = "!f() { echo password=$GH_TOKEN; }; f"
      '';

      # .env is a DERIVED artifact. secrets.env is the single human-edited
      # master: every key it declares wins over .env's value — replace, not
      # just fill gaps. (The old gap-only restore meant an outdated key in
      # .env survived every rebuild forever and the gateway kept using it,
      # because env_loader loads .env with override=True.)
      # Keys secrets.env does NOT declare are left alone:
      #   BW_SERVICE_*        — hermes tooling config, lives in .env only
      #   OPENCODE_GO_API_KEY — owned by the service vault via
      #                         hermes-secrets-sync, so a rate-limited key can
      #                         be swapped from the Bitwarden UI (no SSH).
      envSync = pkgs.writeShellScript "hermes-env-sync" ''
        set -u
        master=/var/lib/hermes/secrets.env
        target=/var/lib/hermes/.env
        if [ ! -f "$master" ]; then
          echo "env-sync: WARNING $master missing — .env left untouched" >&2
          exit 0
        fi
        [ -f "$target" ] || : > "$target"
        tmp=$(mktemp)
        trap 'rm -f "$tmp" "$tmp.new"' EXIT
        cp "$target" "$tmp"
        updated=0
        unchanged=0
        while IFS= read -r mline; do
          case "$mline" in
            [A-Za-z_]*=*)
              mkey=''${mline%%=*}
              mval=''${mline#*=}
              [ -n "$mval" ] || continue
              cur=$(sed -n "s/^$mkey=//p" "$tmp" | head -1)
              if [ "$cur" = "$mval" ]; then
                unchanged=$((unchanged+1))
                continue
              fi
              found=0
              while IFS= read -r line; do
                case "$line" in
                  "$mkey="*) if [ "$found" = 0 ]; then printf '%s=%s\n' "$mkey" "$mval"; found=1; fi ;;
                  *) printf '%s\n' "$line" ;;
                esac
              done < "$tmp" > "$tmp.new"
              [ "$found" = 0 ] && printf '%s=%s\n' "$mkey" "$mval" >> "$tmp.new"
              mv "$tmp.new" "$tmp"
              updated=$((updated+1))
              echo "env-sync: $mkey updated from secrets.env"
              ;;
          esac
        done < "$master"
        if [ "$updated" -gt 0 ]; then cat "$tmp" > "$target"; fi
        echo "env-sync: done: $updated updated, $unchanged unchanged"
      '';

      # No host ssh config any more: the agent runs ON the host. The sandbox
      # reaches host-level tooling through /home/server/.local/bin/hermes-host.
      sshConfig = pkgs.writeText "hermes-ssh-config" ''
        Host localhost
          User server
          IdentityFile /var/lib/hermes/home/.ssh/id_ed25519
          StrictHostKeyChecking accept-new
      '';

      # Native install (cutover 2026-11-11): the agent runs as a systemd unit on
      # the host; shell/file/execute_code calls go into the hermes-sandbox image
      # through `terminal.backend = "docker"`. The old docker-exec wrapper died
      # with the container.
      hermes = pkgs.writeShellApplication {
        name = "hermes";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          export HERMES_HOME="''${HERMES_HOME:-/var/lib/hermes}"
          bin=${hermesAgent}/bin/hermes
          if [ ! -x "$bin" ]; then
            echo "hermes: package binary missing at $bin" >&2
            exit 127
          fi
          exec "$bin" "$@"
        '';
      };

    in
    {
      virtualisation.oci-containers.backend = "docker";

      # RETIRED 2026-11-11: the oci-container ("docker-hermes") and its derived
      # image are gone — Hermes now runs natively (systemd unit below) with the
      # nix-built hermes-sandbox image as its shell backend. The block that used
      # to live here is in git history if we ever need the rollback path.
      environment.systemPackages = [ hermes ];

      # Requisite (not Requires) on the seed: still fail-closed at boot —
      # the container refuses to start while hermes-seed is inactive (its
      # secrets check refuses), but a later hermes-seed restart no longer
      # cascades into stopping the running container. Requires= did exactly
      # that: every rebuild touching the seed script bounced the container
      # and killed the agent's live session.
      # Two-file secrets model (declarative ownership, no chown in bash):
      #   secrets.env = user's keys, root-owned 440, never touched by tooling
      #   .env        = hermes tooling config, server-owned 600
      systemd.tmpfiles.rules = [
        "d ${stateDir} 0750 server users -"
        "d ${stateDir}/home 0750 server users -"
        "f ${stateDir}/.env 0600 server users -"
        "f ${stateDir}/secrets.env 0440 root users -"
      ];

      systemd.services.hermes-seed = {
        description = "Provision hermes state, config and host access";
        # Started at boot on its own (NOT pulled in by docker-hermes' old
        # Requires= — see the Requisite note below).
        wantedBy = [ "multi-user.target" ];
        path = [ pkgs.openssh pkgs.coreutils pkgs.gnused ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          # Run as `server` (the container's user) so every file this unit
          # creates is owned correctly at creation — no chown needed. server
          # already owns ${stateDir} and /home/server/.ssh.
          User = "server";
          Group = "users";
          # /run/hermes is root:root by default; let systemd create it owned by
          # server so the unit can write /run/hermes/env.
          RuntimeDirectory = "hermes";
          RuntimeDirectoryMode = "0750";
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


          # Host access for rebuilds: hermes logs in as `server` (passwordless sudo).
          install -d -m 0700 /home/server/.ssh
          touch /home/server/.ssh/authorized_keys
          chmod 0600 /home/server/.ssh/authorized_keys
          pub=$(cat ${stateDir}/home/.ssh/id_ed25519.pub)
          grep -qF "$pub" /home/server/.ssh/authorized_keys || echo "$pub" >> /home/server/.ssh/authorized_keys

          # hermes resolves API keys from $HERMES_HOME/.env as a FILE, so every
          # secret must be PRESENT in .env — env-var injection is not enough.
          # secrets.env is the read-only master (root:users 440) and .env is
          # derived from it: a key whose VALUE differs is replaced, so a
          # rotated key doesn't get stuck behind the stale one in .env.
          ${envSync} || echo "hermes-seed: WARNING env-sync failed" >&2

          # Validate secrets WARN-ONLY. Never `exit 1`: a missing secret used to
          # abort the whole nixos-rebuild (status 4), bricking the switch. Log
          # loudly, let the system activate; fix .env then restart docker-hermes.
          envFile=${stateDir}/secrets.env
          if [ ! -f "$envFile" ]; then
            echo "hermes-seed: WARNING $envFile missing — container will not start. Create it, then: sudo systemctl restart docker-hermes" >&2
          else
            # OPENCODE_GO_API_KEY is NOT checked here: the service vault owns it
            # (hermes-secrets-sync writes it into .env). Check .env directly.
            grep -q '^OPENCODE_GO_API_KEY=.' ${stateDir}/.env \
              || echo "hermes-seed: WARNING OPENCODE_GO_API_KEY missing/empty in ${stateDir}/.env — vault sync has not run yet" >&2
            for v in \
              HERMES_DASHBOARD_BASIC_AUTH_USERNAME \
              HERMES_DASHBOARD_BASIC_AUTH_PASSWORD \
              HERMES_DASHBOARD_BASIC_AUTH_SECRET
            do
              grep -q "^$v=." "$envFile" \
                || echo "hermes-seed: WARNING $v missing/empty in $envFile" >&2
            done
            grep -q '^GH_TOKEN=.' "$envFile" \
              || echo "hermes-seed: WARNING GH_TOKEN missing — git push will fail" >&2
          fi
        '';
      };

      # Instant materialization: editing secrets.env rewrites .env within a
      # second — no rebuild, no restart. The gateway re-reads .env every turn,
      # so a swapped key is live on the next message.
      systemd.services.hermes-env-sync = {
        description = "Materialize hermes secrets.env into .env";
        path = [ pkgs.coreutils pkgs.gnused ];
        serviceConfig = {
          Type = "oneshot";
          User = "server";
          Group = "users";
          ExecStart = "${envSync}";
        };
      };

      systemd.paths.hermes-env-sync = {
        wantedBy = [ "multi-user.target" ];
        pathConfig.PathModified = [ "${stateDir}/secrets.env" ];
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
