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

## Notes

- Two nixpkgs inputs on purpose: `nixpkgs` (system) and `nixpkgs-hm`
  (Home Manager) for independent update cadence.
- Inputs with upstream binary caches (helix, logseq-nightly, noctalia) do NOT
  follow our nixpkgs — overriding it would make their caches miss.
- First switch after the dendritic refactor: run `nxswitch` before
  `hmswitch` (activates the helix cache for the HM build).
- See `REFACTOR_PLAN.md` for the full design rationale.
