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
sudo install -d /var/lib/harmonia
sudo nix-store --generate-binary-cache-key t490s-cache-1 \
  /var/lib/harmonia/cache-key.pem /var/lib/harmonia/cache-key.pub
sudo systemctl restart harmonia.service
cat /var/lib/harmonia/cache-key.pub
```

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
3. Rebuild the server (remotely fine: `ssh pebor@t490s`, then `nxswitch`).
4. Import `build-client` in the client's host file and switch it.

### Later (deliberately not set up yet)

- `nix.settings.max-jobs = 0` on clients for hard offload (no local builds)
- nextcloud / hermes / personal projects as docker compose stacks
- Hetzner reverse proxy / tailscale exit node

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
