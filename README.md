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

## Notes

- Two nixpkgs inputs on purpose: `nixpkgs` (system) and `nixpkgs-hm`
  (Home Manager) for independent update cadence.
- Inputs with upstream binary caches (helix, logseq-nightly, noctalia) do NOT
  follow our nixpkgs — overriding it would make their caches miss.
- The `nixConfig` block in `flake.nix` mirrors the caches from
  `modules/base/nix.nix` so they are active even during `nixos-install`
  (before the system config applies). Keep the two in sync.
- `modules/home/packages-heavy.nix` holds big/rarely-used programs
  (vscode, qemu, godot, libreoffice, kotlin-native, emacs, ollama, zed) so
  fresh installs can skip the aspect and boot fast; t490s/desktop import it.
- First switch after the dendritic refactor: run `nxswitch` before
  `hmswitch` (activates the helix cache for the HM build).
- See `REFACTOR_PLAN.md` for the full design rationale.
