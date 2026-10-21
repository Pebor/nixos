# nixos config

Dendritic layout with flake-parts. One flake for NixOS + standalone Home Manager.

## Layout

- `modules/` — every `.nix` file is auto-imported (flake-parts + import-tree)
  - `base/` — shared by all hosts (nix settings/caches, system, user)
  - `features/` — one file per feature, each can define a NixOS aspect
    (`flake.modules.nixos.<name>`) and/or a Home Manager aspect
    (`flake.modules.homeManager.<name>`)
  - `home/` — user-side aspects (fish, package sets, llm)
  - `hosts/` — one file per host: composes aspects + defines both outputs
- `hardware/` — `nixos-generate-config` output per host

## Daily use

```bash
nxswitch   # nh os switch ~/nixos          (system)
hmswitch   # nh home switch ~/nixos        (standalone HM, no boot entries)

nxupdate   # update system nixpkgs         (every few weeks)
hmupdate   # update HM nixpkgs             (daily)
```

(aliases defined in `modules/home/fish.nix`)

## Adding a host

1. `hardware/<name>.nix` (from `nixos-generate-config`)
2. `modules/hosts/<name>.nix` — copy an existing host, adjust the aspect
   imports and host-specific settings. Done.

### Fresh install with disko (e.g. t14)

1. Boot the NixOS ISO, clone this repo, check the disk with `lsblk`
   (device is set in `hardware/<name>-disko.nix`).
2. `sudo nix run github:nix-community/disko/latest -- --mode disko hardware/<name>-disko.nix`
   (wipes the disk; btrfs + swap, mounts under `/mnt`)
3. `sudo nixos-generate-config --no-filesystems --root /mnt` and copy the
   result over `hardware/<name>.nix` (`--no-filesystems` because disko owns
   `fileSystems`). Set both `stateVersion`s in the host file to the ISO's
   release.
4. `sudo nixos-install --flake .#<name> --root /mnt`, then
   `sudo nixos-enter --root /mnt -c 'passwd pebor'` (no password is set by
   the config, and greetd needs one).
5. After first boot, bootstrap standalone HM once:
   `nix run nixpkgs#nh -- home switch ~/nixos` — afterwards `hmswitch` works.

## t490s-server — headless build worker + binary cache

The old t490s runs a second, headless config (`t490s-server`) alongside its
desktop one (`t490s`). Same hardware file, no reinstall. It offloads nix
builds from other machines (distributed builds) and serves its store as a
binary cache (harmonia) over tailscale; docker is ready for compose stacks.

The working account on the server is **`server`** (SSH key-only, passwordless
wheel sudo). The old `pebor` account has no remote access there; its files in
`/home/pebor` are archived as-is until you feel like cleaning them up.

### Switching the laptop over (first time)

On the t490s, lid open:

```bash
cd ~/nixos && git pull
sudo nixos-rebuild switch --flake .#t490s-server
```

Tailscale state survives the switch and the hostname is unchanged, so it
stays the same `t490s` machine on the tailnet (no re-auth). Then bootstrap
the cache and wire the clients:

```bash
# 1. note the tailscale IP
tailscale status

# 2. one-time harmonia signing key
sudo install -d -m 755 /var/lib/harmonia
sudo nix-store --generate-binary-cache-key t490s-cache-1 \
  /var/lib/harmonia/cache-key.pem /var/lib/harmonia/cache-key.pub
sudo chmod 600 /var/lib/harmonia/cache-key.pem
sudo systemctl restart harmonia.service
cat /var/lib/harmonia/cache-key.pub

# 3. repo + first Home Manager switch for the server user
sudo cp -a /home/pebor/nixos /home/server/nixos
sudo chown -R server:users /home/server/nixos
# then from a client: ssh server@t490s, and in that session:
nh home switch ~/nixos -c server@t490s-server
# afterwards hmswitch/nxswitch aliases work (they point at the server attrs)
```

The `server` user's `~/nixos` is a plain clone of the public GitHub repo —
anonymous `git pull` works, no credentials needed.

Back on the t14, fill `builderIp` (tailscale IP) and `cachePubKey` (the .pub
contents) into `modules/features/build-client.nix`, and move the nixbuild
key into place (generated earlier as pebor):

```bash
sudo install -m 600 -o root -g root ~/.ssh/nixbuild_ed25519 /root/.ssh/nixbuild_ed25519
rm ~/.ssh/nixbuild_ed25519
nxswitch
```

Verify from the t14:

```bash
nix store ping --store ssh-ng://nixbuild@<ip>   # build channel
curl http://<ip>:5000/nix-cache-info            # cache
nix build nixpkgs#hello --max-jobs 0            # builds on the server
```

Then close the lid — suspend is disabled, the laptop ignores it.

Rollback: `sudo nixos-rebuild switch --flake ~/nixos#t490s`.

### Daily flow / cache warming

The server builds whatever the clients will need *before* they need it.
Cache hits require an identical tree, so the client pushes its working tree
(git history is irrelevant here):

```bash
hmupdate            # or nxupdate — bump the lock as usual, no commit needed
cache-push          # mirror ~/nixos to the server; night timer picks it up
cache-push --now    # ...or build immediately
# next morning, on the t14:
hmswitch / nxswitch # substitutes from the server instead of compiling
```

`cache-warm` on the server builds the t14 system + HM closures into GC-rooted
out-links (old results roll out via the weekly 30-day GC). The night timer
(03:30) is prepared but disabled — after testing with
`sudo systemctl start cache-warm`, enable it by uncommenting `wantedBy` in
`modules/features/cache-warm.nix`.

### Adding another build client

1. On the client: `sudo ssh-keygen -t ed25519 -N "" -C "nixbuild@<host>" -f /root/.ssh/nixbuild_ed25519`
2. Append the .pub to `nixbuild`'s keys in `modules/features/build-worker.nix`
   (keep the `restrict` prefix).
3. Rebuild the server (remotely fine: `ssh server@t490s`, then `nxswitch`).
4. Import `build-client` in the client's host file and switch it.

### Hermes agent

[Hermes](https://hermes-agent.nousresearch.com) (Nous Research's agent) runs
in Docker on t490s-server: a long-lived gateway (Telegram-ready), the web
dashboard on **:9119**, a shared `~/nixos` tree, and an SSH back-channel to
the host for rebuilds. Model: `mimo-v2.6-pro` via your OpenCode Go key.

He edits `modules/` like anyone else — flow is: edit → `nixos-rebuild` over
SSH → push. `approvals.mode: smart` makes him escalate sudo/rebuild/push
commands for your confirmation (in whatever channel you're on); `SOUL.md`
in `/var/lib/hermes` is his brief, edit it to taste.

**One-time bootstrap** (secrets stay in this file — no sops needed, never in
the repo or the store):

```bash
sudo install -d -m 750 /var/lib/hermes
sudo tee /var/lib/hermes/.env >/dev/null <<'EOF'
OPENCODE_GO_API_KEY=<key>              # opencode.ai console
GH_TOKEN=<fine-grained PAT>            # contents:write on Pebor/nixos (push only)
HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=<pick one>
HERMES_DASHBOARD_BASIC_AUTH_SECRET=<openssl rand -base64 32>
# optional, for Telegram — or use "Create with QR" in the dashboard later:
# TELEGRAM_BOT_TOKEN=
# TELEGRAM_ALLOWED_USERS=
EOF
sudo chmod 600 /var/lib/hermes/.env
```

Then switch (remotely fine) and verify:

```bash
ssh server@t490s 'cd ~/nixos && sudo nixos-rebuild switch --flake .#t490s-server'
curl -s http://t490s:9119/api/status | jq '.auth_required, .auth_providers'
# -> true, ["basic"]   (the container refuses to start without the .env above)
```

**Talking to him**

- Terminal, from any machine: `hermes` (Home Manager wrapper that ssh-es to
  the server; `HERMES_SSH_DEST=...` overrides the target). On the server
  itself `hermes` runs him locally via `docker exec`. Full CLI: `hermes chat`,
  `hermes config set …`, `hermes pairing approve …`.
- Browser: `http://t490s:9119` over the tailnet (dashboard login from the
  `HERMES_DASHBOARD_BASIC_AUTH_*` lines). Sessions, analytics, config, and
  a Chat tab. Hermes Desktop can attach to it as a remote gateway too.
- Telegram: dashboard → *Messaging → Telegram* → **Create with QR** (it makes
  the bot, writes the token, restarts the gateway), or manually: @BotFather
  `/newbot`, add `TELEGRAM_BOT_TOKEN` + `TELEGRAM_ALLOWED_USERS=<your id>`
  to `/var/lib/hermes/.env`, `sudo systemctl restart docker-hermes`. Keep the
  allowlist (or use DM pairing) — never `GATEWAY_ALLOW_ALL_USERS`; the bot can
  run commands on the box.

State lives in `/var/lib/hermes` (config, sessions, skills, memory). The
image is `latest`: `docker pull nousresearch/hermes-agent && sudo systemctl
restart docker-hermes` to update (`docker restart hermes` is enough after
editing `/var/lib/hermes/.env` only — hermes re-reads it). `hermes-seed`
explains itself in the journal if `.env` is missing something
(`journalctl -u hermes-seed`).

### Nextcloud & public services (live since 2026-10-17)

- **Nextcloud** (35.x) as a docker compose stack at `~/nextcloud/` on
  t490s-server: `nextcloud:latest` (digest-pinned) + MariaDB LTS + Redis +
  cron sidecar. Data at `/var/lib/nextcloud/{html,db}`; secrets in
  `~/nextcloud/.env` (chmod 600) and `secrets.md`; DB dumps in
  `~/nextcloud/backups/`. Admin user `pebor`. Occ: `docker exec
  nextcloud-app-1 php occ ...`.
- **Access URLs** (since 2026-10-18): one canonical URL `https://cloud.pebor.me`
  everywhere; Nextcloud's `overwritehost`/`overwriteprotocol` pin all generated
  links to it (share links work from anywhere). Two front doors: (a) home/tailnet
  clients resolve the name to 100.103.136.50 via Tailscale Split DNS (admin
  console route) -> local Caddy in `~/edge/compose.yaml` (Let's Encrypt DNS-01
  via a Cloudflare API token in `~/edge/.env`, never committed) + dnsmasq on
  :53 -> Nextcloud `:8080`; (b) away clients hit the Cloudflare DNS-only
  record -> 178.104.163.147 -> Hetzner VPS `lesbian-4gb` (100.117.69.56 on the
  tailnet) running Caddy with auto-TLS, reverse-proxying
  `t490s.tail16a6c9.ts.net:8080` over Tailscale. Ports 80/443 open in the
  Hetzner firewall. The fleet has no SSH access to the VPS (sshd closed) -
  Pebor administers its Caddyfile manually (it carries the same HSTS header and
  CalDAV-discovery redir as `~/edge`).
- Super Productivity syncs through Nextcloud WebDAV; Hermes integrates via
  the `nextcloud-sp` skill (WebDAV reads, CalDAV `hermes` bridge for writes).
- Other compose stacks on the host: none active. `sp1-team-karate` (postgres),
  example-project `adminer`, `server-db` and `semestra-app-db` were all removed
  2026-10-21: leftovers from manual `docker run` experiments, no compose file on
  disk, no traffic since 2026-10-17, no service referencing them. Their images
  and volumes were pruned the same day (~5 GB reclaimed).

### Later (deliberately not set up yet)

- `nix.settings.max-jobs = 0` on clients for hard offload (no local builds)
- Nextcloud backup automation - LOCAL half wired 2026-10-21, inside the compose
  stack (`~/nextcloud/backup/`, crond at 03:30): all-databases dump + user-data
  tarball (html/{data,config,themes} only - code comes from the pinned image) +
  config/secrets bundle with an app manifest, retention 14 d / 7 daily + 4
  weekly / 14 d (~83 MB per night),
  log at `~/nextcloud/backups/backup.log`. Restore verified (0 import errors,
  table/row counts identical). Deliberately NOT in this flake: the stack is
  compose-managed, so its backups live with it. Offsite restic -> VPS is still
  not wired - needs SSH access to the VPS first (currently closed by design).
- tailscale exit node

## Notes

- Two nixpkgs inputs on purpose: `nixpkgs` (system) and `nixpkgs-hm`
  (Home Manager) for independent update cadence.
- Inputs with upstream binary caches (helix, logseq-nightly, noctalia) do NOT
  follow our nixpkgs — overriding it would make their caches miss.
- The `nixConfig` block in `flake.nix` mirrors the caches from
  `modules/base/nix.nix` so they are active even during `nixos-install`
  (before the system config applies). Keep the two in sync.
- First switch after the dendritic refactor: run `nxswitch` before
  `hmswitch` (activates the helix cache for the HM build).
- See `REFACTOR_PLAN.md` for the full design rationale.
