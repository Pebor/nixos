# Refactor Plan: Dendritic Pattern with Flake Parts

> **STATUS: IMPLEMENTED** — this document is kept as the design record.
> Baseline before refactor: `c77e773` ("snapshot before dendritic refactor").
> Deviations found during implementation:
> - nixpkgs `programs.hyprlock.enable` unconditionally force-enables the
>   system-side hypridle → the NixOS hyprland aspect sets
>   `services.hypridle.enable = lib.mkForce false` (this was the actual
>   root cause of the hypridle bug, even before the refactor).
> - `pkgs.hyprlandPlugins.hyprscrolling` no longer exists in nixpkgs
>   (merged into Hyprland) → dropped from t420.
> - `llm` + `llm.withPlugins` in the same package list conflict (latent
>   bug in the old, never-imported llm.nix) → only the withPlugins
>   variant is installed.
> - `noctalia-qs` input removed (no longer exists upstream).
> - Inputs with upstream caches (helix, logseq-nightly, noctalia) do NOT
>   follow our nixpkgs — overriding it makes their caches miss.

Working document for deciding whether/how to refactor this config.
Based on: https://github.com/Doc-Steve/dendritic-design-with-flake-parts

Baseline before refactor: commit `c77e773` ("snapshot before dendritic refactor").

---

## 1. Problems found in the current config

### Duplication
- `t420` and `t420-server` home-manager package files are **byte-identical** copies; vs `t490s` they differ only by which lines are commented out.
- The locale / i18n / timezone / user / nix-settings blocks are copy-pasted across all 3 `configuration.nix` files.
- `home.nix` files are near-identical except `stateVersion`.
- `hosts/t420-server/home-manager/` exists with real files (llm.nix, packages/...) but has **no flake output** — dead code.

### Structural drift → bugs
- **hypridle bug (root cause found):** `hosts/t490s/configuration.nix` sets `services.hypridle.enable = true` (NixOS layer, empty settings → its own config + systemd unit), while `home-manager/common/hypridle.nix` also configures `services.hypridle` with your real settings. The two layers fight, so the system behaves differently from what the HM file says. The same pattern (NixOS enables `hyprlock`, HM also configures it) invites more of these.
- The NixOS configs import `inputs.home-manager.nixosModules.default` but never define `home-manager.users.*` → dead import on every host.

### Two flakes = duplicated bookkeeping
- Root `flake.lock` and `home-manager/flake.lock` pin **different nixpkgs revisions** — two package universes, double downloads and store usage wherever versions overlap.
- Every input exists twice (or is missing in one flake); every update requires `nix flake update` in two directories.

### Build times / caching
- `helix` builds from git source (no cache configured) — a full Rust build.
- `mangowc` builds from git source (no cache configured).
- ~~The `lmms` alpha overlay rebuilds lmms (large Qt app) locally on every nixpkgs bump.~~ → **decided: remove lmms entirely.**
- Substituters (noctalia, logseq) are only configured on `t490s`.
- `niri` flake input is pinned but never referenced (unused fetch on every eval).

---

## 2. Key design: ONE flake, TWO nixpkgs inputs, standalone Home Manager

Requirement (yours): update Home Manager every day or so, but the system nixpkgs only
every few weeks. Installing a user program must not rebuild the system or create boot entries.

Solution: merge both flakes into one root flake, but keep **two nixpkgs inputs** with
independent update cadence:

```nix
nixpkgs.url    = "github:nixos/nixpkgs/nixos-unstable";  # system — update every few weeks
nixpkgs-hm.url = "github:nixos/nixpkgs/nixos-unstable";  # HM    — update daily
```

- `nixosConfigurations` build against `nixpkgs`; `homeConfigurations` against `nixpkgs-hm`.
- Home Manager stays **standalone**: `home-manager switch --flake ~/nixos#pebor@t490s`
  applies to your user session only. No boot entries, no system closure, no rebuild of
  system services. Exactly your current workflow.
- HM-facing inputs follow `nixpkgs-hm` (`helix`, `helium`, `home-manager` itself), so the
  daily HM update cadence doesn't drag the system along.
- System-facing inputs follow `nixpkgs` (`mangowc`, `noctalia`, `logseq-nightly`, `stylix`).

Update commands become:

```bash
nix flake lock --update-input nixpkgs-hm --flake ~/nixos   # daily HM refresh
nix flake lock --update-input nixpkgs    --flake ~/nixos   # system refresh, when you feel like it
```

What you gain vs. two separate flakes: one flake file, one lock file, every shared input
declared once, dendritic feature files that can define both layers in one place, and
`flake check`-ability of the whole setup. What you keep: fully independent cadence and
standalone HM. The "two nixpkgs universes" overlap that exists today stays — but now it's
*intentional* instead of accidental drift.

Note: `stylix` is used on both layers but follows `nixpkgs` (system cadence). Theming
packages are tiny; the skew is harmless. (If it ever annoys you: a `stylix-hm` input is a
2-line change.)

---

## 3. What the Dendritic pattern is (60-second version)

> Flip the organization: instead of "host → has services/apps/user settings",
> organize by **feature → used on hosts**.

- Every `.nix` file under `modules/` is a **flake-parts module** (auto-imported via `import-tree`).
- A feature file defines **aspects** for each configuration context it touches:
  - `flake.modules.nixos.<name>` — system-side of the feature
  - `flake.modules.homeManager.<name>` — user-side of the feature
- Hosts become **thin compositions**: a list of aspect imports plus a handful of host-specific settings.
- Enabling a feature = importing its module. One file owns *everything* about that feature across layers → no more cross-layer drift (the hypridle bug class disappears by construction).

Tools used: `flake-parts` (framework, provides `flake.modules`), `vic/import-tree` (auto-imports all files in `modules/`; `_`-prefixed files/dirs are skipped).
Deliberately **not** used: `vic/flake-file` (regenerates `flake.nix` from code — extra codegen step, not worth it for this size).

---

## 4. Proposed structure

### Now
```
flake.nix                  # NixOS flake (own nixpkgs)
greetd.nix
home-manager/
  flake.nix                # SEPARATE HM flake (own nixpkgs!)  ← delete
  flake.lock                                                  ← delete
  common/                  # fish, hyprland, hypridle, hyprlock, hyprpaper
hosts/
  t490s/{default,configuration,hardware-configuration}.nix
  t490s/home-manager/{home,hyprland,llm}.nix + packages/{apps,programming,school,terminalPrograms,local}.nix
  t420/...                 # ~identical copies (keep host, dedupe content)
  t420-server/...          # ~identical copies (keep host, dedupe content)
```

### After
```
flake.nix                  # ONE flake: NixOS + HM outputs, two nixpkgs inputs
flake.lock
hardware/
  t490s.nix  t420.nix  t420-server.nix    # existing hardware-configuration.nix files
  desktop.nix                             # placeholder until nixos-generate-config on the new PC
modules/
  base/
    nix.nix                # nix settings: caches, flakes, allowUnfree, auto-optimise-store
    locale.nix             # timezone, i18n, keymaps
    user.nix               # users.users.pebor + fish as shell
  features/
    hyprland.nix           # ONE file: nixos aspect + homeManager aspect (+ hypridle/lock/paper)
    niri.nix               # programs.niri + niri flake input kept, niri.cachix.org
    mango.nix
    cosmic.nix
    plasma.nix
    greetd.nix
    stylix.nix             # nixos + homeManager aspects, one base16Scheme definition
    gaming.nix             # steam, gamemode, gamescope
    desktop-apps.nix       # pipewire, bluetooth, printing, fonts, kdeconnect...
    tailscale.nix
    ssh-server.nix
    oomd.nix / nix-ld.nix / laptop-power.nix ...
  home/
    base.nix               # username, session vars, programs.home-manager
    fish.nix               # fish + aliases (paths updated, no --impure!)
    packages-terminal.nix
    packages-programming.nix
    packages-apps.nix      # affinity-nix stays as commented line
    packages-school.nix
    llm.nix
  hosts/
    t490s.nix              # nixosConfigurations.t490s + homeConfigurations."pebor@t490s"
    t420.nix               # kept for future work
    t420-server.nix        # kept for future work + HM output wired up
    desktop.nix            # NEW: your desktop PC migration target
```

Files land in `modules/` and are **automatically available** — no `imports` bookkeeping,
no `default.nix` wrapper files (all those 11-line `default.nix` re-exporters disappear).

Gone entirely: `packages-local.nix` / rmenu (you don't use it → **no more `--impure`,
everything evaluates pure**), lmms + its overlay, the dead HM NixOS-module imports.

---

## 5. How the modules look (concrete examples from your config)

### Root `flake.nix` (entire file — it stays hand-written and thin)
```nix
{
  description = "pebor's NixOS + Home Manager configurations";

  inputs = {
    # --- two nixpkgs, independent cadence (see §2) ---
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";        # system
    nixpkgs-hm.url = "github:nixos/nixpkgs/nixos-unstable";     # home manager

    flake-parts.url = "github:hercules-ci/flake-parts";
    import-tree.url = "github:vic/import-tree";

    # --- HM-side inputs (follow nixpkgs-hm) ---
    home-manager = { url = "github:nix-community/home-manager"; inputs.nixpkgs.follows = "nixpkgs-hm"; };
    helix    = { url = "github:helix-editor/helix";             inputs.nixpkgs.follows = "nixpkgs-hm"; };
    helium   = { url = "github:schembriaiden/helium-browser-nix-flake"; inputs.nixpkgs.follows = "nixpkgs-hm"; };
    zen-browser.url = "github:0xc000022070/zen-browser-flake";
    rose-pine-hyprcursor.url = "github:ndom91/rose-pine-hyprcursor";
    otter-launcher.url = "github:kuokuo123/otter-launcher";
    affinity-nix.url = "github:mrshmllow/affinity-nix";         # kept, stays disabled in packages-apps

    # --- system-side inputs (follow nixpkgs) ---
    stylix       = { url = "github:nix-community/stylix";       inputs.nixpkgs.follows = "nixpkgs"; };
    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/*";  # kept: faster, lazytrees
    mangowc      = { url = "github:mangowm/mango";              inputs.nixpkgs.follows = "nixpkgs"; };
    logseq-nightly = { url = "github:Bad3r/nix-logseq-git-flake"; inputs.nixpkgs.follows = "nixpkgs"; };
    noctalia     = { url = "github:noctalia-dev/noctalia-shell"; inputs.nixpkgs.follows = "nixpkgs"; };
    noctalia-qs  = { url = "github:noctalia-dev/noctalia-qs";    inputs.nixpkgs.follows = "nixpkgs"; };
    niri         = { url = "github:YaLTeR/niri";                inputs.nixpkgs.follows = "nixpkgs"; };  # kept

    # dropped: dms (was enable=false), shko (commented out)
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];
      imports = [
        inputs.flake-parts.flakeModules.modules   # provides the `flake.modules` option
        (inputs.import-tree ./modules)            # auto-imports every file in modules/
      ];
    };
}
```

### A base feature — `modules/base/nix.nix`
```nix
{
  flake.modules.nixos.nix-settings = {
    nix.settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;
      substituters = [
        "https://cache.nixos.org/"
        "https://cache.garnix.io"
        "https://nix-logseq-git-flake.cachix.org"
        "https://noctalia.cachix.org"
        "https://helix.cachix.org"        # NEW: turns helix source build into a download
        "https://niri.cachix.org"         # NEW: official niri cache
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
        "nix-logseq-git-flake.cachix.org-1:DSBNW07PSRyCvS926tpIWahb53OIydwwZhsP6LhJNZo="
        "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4="
        # helix + niri keys copied from their official repos during migration
      ];
    };
    nixpkgs.config.allowUnfree = true;
    documentation.man.generateCaches = false;
  };

  flake.modules.homeManager.nix-settings = {
    nixpkgs.config.allowUnfree = true;
  };
}
```

### The flagship example — `modules/features/hyprland.nix`
One file owning the whole feature, both layers. **This is what fixes the hypridle bug:**
the NixOS aspect deliberately does NOT enable `services.hypridle`; the user session owns it.

```nix
{ inputs, ... }: {
  # ---- system side ----
  flake.modules.nixos.hyprland = {
    programs.hyprland.enable = true;
    programs.hyprlock.enable = true;
    programs.xwayland.enable = true;
    # services.hypridle is intentionally NOT here — user session owns it.
  };

  # ---- user side ----
  flake.modules.homeManager.hyprland = { pkgs, ... }: {
    home.packages = with pkgs; [
      hyprpaper dunst waybar tofi brightnessctl
      inputs.rose-pine-hyprcursor.packages.${pkgs.system}.default
      wofi-emoji wleave grimblast wl-clipboard
      libnotify libqalculate libinput libwacom
      rose-pine-cursor rose-pine-gtk-theme rose-pine-icon-theme
    ];

    wayland.windowManager.hyprland = {
      enable = true;
      settings = {
        # ...everything currently in home-manager/common/hyprland.nix...
      };
    };

    services.hypridle = {
      enable = true;
      settings = { /* ...current common/hypridle.nix — the ONLY hypridle config now... */ };
    };

    programs.hyprlock = {
      enable = true;
      settings = { /* ...current common/hyprlock.nix... */ };
    };

    services.hyprpaper = {
      enable = true;
      settings = { /* ...current common/hyprpaper.nix... */ };
    };
  };
}
```

### A host — `modules/hosts/t490s.nix` (the whole file)
```nix
{ inputs, ... }: {
  # ==== the outputs ====
  flake.nixosConfigurations.t490s = inputs.nixpkgs.lib.nixosSystem {
    specialArgs = { inherit inputs; };
    modules = [
      inputs.self.modules.nixos.host-t490s
      ../../hardware/t490s.nix
      inputs.stylix.nixosModules.default
      inputs.determinate.nixosModules.default
    ];
  };

  # standalone HM, built from nixpkgs-hm — daily-cadence side
  flake.homeConfigurations."pebor@t490s" = inputs.home-manager.lib.homeManagerConfiguration {
    pkgs = inputs.nixpkgs-hm.legacyPackages.x86_64-linux;
    extraSpecialArgs = { inherit inputs; };
    modules = [
      inputs.self.modules.homeManager.host-t490s
      inputs.stylix.homeModules.stylix
    ];
  };

  # ==== aspect compositions (the "host profile") ====
  flake.modules.nixos.host-t490s = { pkgs, ... }: {
    imports = with inputs.self.modules.nixos; [
      nix-settings locale user
      hyprland niri mango cosmic greetd
      stylix gaming desktop-apps tailscale
    ];

    networking.hostName = "t490s";
    system.stateVersion = "24.11";

    # host-specific leftovers: udev rules, oomd, nix-ld,
    # auto-cpufreq, opentabletdriver, logseq+noctalia packages...
    # (lmms overlay: gone)
  };

  flake.modules.homeManager.host-t490s = {
    imports = with inputs.self.modules.homeManager; [
      base fish hyprland stylix
      packages-terminal packages-programming packages-apps
      packages-school llm
    ];

    home.stateVersion = "24.11";

    # host-specific deltas survive as tiny overrides:
    wayland.windowManager.hyprland.settings.bind = [
      "$mainMod, o, exec, ~/.config/hypr/otter.sh"
    ];
  };
}
```

`t420` / `t420-server` look the same with different import lists
(server: no hyprland/gaming/desktop-apps; instead `ssh-server`; `stateVersion = "25.05"`).
Both get `homeConfigurations` outputs — t420-server's dead HM dir becomes live.

### The new desktop host — `modules/hosts/desktop.nix`
Composition close to t490s minus laptop concerns (no `auto-cpufreq`/`thinkfan`/touchpad
settings, no powertop). Ships with a placeholder `hardware/desktop.nix` containing only
`{ }` + a FIXME comment — replace it with `nixos-generate-config` output on the real
machine before ever switching to it. Everything else (hostname, stateVersion, NVIDIA or
AMD feature module if needed) gets filled in during the actual migration.

---

## 6. Workflow after the refactor

| Task | Now | After |
|---|---|---|
| System switch | `nh os switch ~/nixos` | same: `nh os switch ~/nixos` (picks host from hostname) |
| HM switch | `nh home switch ~/nixos/home-manager -- --impure` | `nh home switch ~/nixos` — **no `--impure`, pure eval** |
| Update HM inputs (daily) | `nix flake update` in home-manager/ | `nix flake lock --update-input nixpkgs-hm --flake ~/nixos` |
| Update system inputs | `nix flake update` in ~/nixos | `nix flake lock --update-input nixpkgs --flake ~/nixos` |
| Add a host | copy+edit ~6 files across hosts/ | one `modules/hosts/x.nix` + `hardware/x.nix` |
| Add a program everywhere | edit 3 copies of apps.nix | edit `modules/home/packages-apps.nix` once |
| Change a shared setting | edit 3 configuration.nix | edit one feature file |
| Fix hyprland | look in 2 layers, 5+ files | one file: `modules/features/hyprland.nix` |

Fish aliases get updated paths in `modules/home/fish.nix` (`nxswitch`, `hmswitch` keep
working; `--impure` disappears; the two update-cadence commands can become aliases too,
e.g. `nxupdate` / `hmupdate`).

rmenu is gone → nothing impure remains → `nix flake check` and pure evaluation work everywhere.

---

## 7. Caching / build-time improvements (the big wins, ordered)

1. **One flake, one lock, inputs declared once.** No more double fetches, no accidental
   two-nixpkgs drift; the remaining two nixpkgs universes are intentional (your cadence).
2. **`helix.cachix.org`** — turns the biggest recurring source build into a download.
   Matters especially with your daily HM updates.
3. **`niri.cachix.org`** + checking for an official `mangowc` cache at migration time.
4. **lmms overlay removed** (your decision) — eliminates the largest recurring local build.
5. **rmenu removed** — no impure eval, no local Rust rebuild on every switch.
6. `auto-optimise-store = true`, `documentation.man.generateCaches = false` on **all** hosts.
7. Habit: prefer targeted `--update-input` (as in §6) over full `nix flake update` —
   only the pinned set you chose moves; everything else (and its caches) stays valid.

---

## 8. Answers to your questions

**Is it possible?** Yes — this config is actually a good fit: your `common/` + per-host-delta
layout is already 60% of the dendritic idea, just expressed through file copies.

**Positive outcomes?**
- Duplication → single feature files. Verified win: the 3 copies of packages/config collapse into one.
- The hypridle bug class disappears — one file owns a feature across both layers.
- New hosts become boring (one small file) — relevant with the desktop PC coming.
- Combined with the flake merge + caches: measurably faster builds and smaller store.

**Simpler?** Structurally yes (fewer files, no copy-paste, no `default.nix` chains,
flake.nix gets *thinner*). One new concept to learn — `flake.modules.<class>.<aspect>` —
and flake-parts error messages can be obtuse while you get used to them. With your
"new host soon + t420 projects waiting" situation, the composition model pays off quickly.

---

## 9. Decisions — status after your feedback

| # | Question | Status |
|---|----------|--------|
| 1 | Full dendritic, or 80/20 shared-modules first? | **Full dendritic** (recommended; say the word if you'd rather start with 80/20). |
| 2 | Merge flakes? | ✅ One flake, **two nixpkgs inputs** to keep your update cadence; HM stays standalone. |
| 3 | t420 / t420-server | ✅ Keep both, dedupe into aspects, wire up `pebor@t420-server` HM output. |
| 4 | Inputs | ✅ Keep `niri` (wired into a niri feature + cachix) and `affinity-nix` (stays disabled/commented). Drop `dms` (was `enable=false`) and `shko` — **flag if you want dms kept**. |
| 5 | determinate | ✅ Keep, per-host import (t490s, desktop later). |
| 6 | lmms + overlay | ✅ Remove. |
| 7 | rmenu / `--impure` | ✅ Remove entirely → pure evaluation everywhere. |
| 8 | NEW: desktop host | ✅ Add `modules/hosts/desktop.nix` + placeholder `hardware/desktop.nix`. |

---

## 10. Migration plan (incremental, always buildable)

0. ~~Commit everything first~~ — done: baseline `c77e773`. Refactor happens on top; consider a branch.
1. Record baselines: `nixos-rebuild build` + `home-manager build` for t490s/t420;
   save the closure paths for later comparison.
2. Rewrite root `flake.nix`: add flake-parts + import-tree + `nixpkgs-hm`, move all
   surviving inputs over, drop dms/shko. Delete `home-manager/flake.nix` + its lock.
   `nix flake lock` → one lock.
3. Move hardware files to `hardware/`; create `modules/base/*` (nix, locale, user).
4. Port features one by one, building after each: hyprland (with the hypridle fix),
   fish, packages-*, stylix, greetd, niri, gaming, desktop-apps, ...
   Remove lmms overlay and rmenu here.
5. Create `modules/hosts/*.nix` compositions for all 4 hosts; wire
   4 `nixosConfigurations` + 3 `homeConfigurations` (t490s, t420, t420-server).
6. Compare closures against step-1 baselines (`nix store diff-closures`) —
   goal: identical except intended changes (§ below).
7. Switch on `t490s` (easiest rollback), then the others; delete old
   `hosts/*` trees and `home-manager/`.
8. Update fish aliases; update README (TODOs mostly resolved by this).
9. Later, on the desktop PC: `nixos-generate-config` → `hardware/desktop.nix`,
   fill host specifics, first switch.

Rollback at any point = `git checkout c77e773` (or the branch point) + rebuild from the old lock.

### Intended behavior changes (explicit, not accidental)
- hypridle runs **only** as the HM user service with your settings (t490s NixOS-level enable removed).
- Dead HM NixOS-module imports removed.
- Substituters unified across hosts; `helix` + `niri` cachix added.
- `dms` input dropped (pending your veto).
- lmms, rmenu gone.
- t420-server gets a working `pebor@t420-server` HM output.
- New (unbootable-until-hardware-file) `desktop` host entry exists.
