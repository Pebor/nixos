# Refactor Plan: Dendritic Pattern with Flake Parts

Working document for deciding whether/how to refactor this config.
Based on: https://github.com/Doc-Steve/dendritic-design-with-flake-parts

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
- Inputs pinned but unused: `niri` (HM flake, never referenced), `affinity-nix` (only in comments), `dms` (module imported with `enable = false`).

### Two flakes = two nixpkgs = double work
- Root `flake.lock` pins nixpkgs `1d4e0f86...`, `home-manager/flake.lock` pins `e8273b29...`.
- System and Home Manager build against **different package universes**: double evaluations, double downloads, double store space, version skew.

### Build times / caching
- `helix` builds from git source (no cache configured) — a full Rust build.
- `mangowc` builds from git source (no cache configured).
- The `lmms` alpha overlay rebuilds lmms (large Qt app) locally on **every nixpkgs bump**.
- Both source-inputs follow `nixpkgs`, so every nixpkgs update rebuilds them even if the input itself didn't change.
- Substituters (noctalia, logseq) are only configured on `t490s`.

---

## 2. What the Dendritic pattern is (60-second version)

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

## 3. Proposed structure

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
  t420/...                 # ~identical copies
  t420-server/...          # ~identical copies + dead HM dir
```

### After
```
flake.nix                  # ONE flake: NixOS + HM outputs, ONE nixpkgs
flake.lock
hardware/
  t490s.nix  t420.nix  t420-server.nix    # hardware-configuration.nix files (not flake modules)
modules/
  base/
    nix.nix                # nix settings: caches, flakes, allowUnfree, auto-optimise-store
    locale.nix             # timezone, i18n, keymaps
    user.nix               # users.users.pebor + fish as shell
  features/
    hyprland.nix           # ONE file: nixos aspect + homeManager aspect (+ hypridle/lock/paper)
    niri.nix
    mango.nix
    cosmic.nix
    plasma.nix
    greetd.nix
    stylix.nix             # nixos + homeManager aspects, one base16Scheme definition
    gaming.nix             # steam, gamemode, gamescope
    desktop.nix            # pipewire, bluetooth, printing, fonts, kdeconnect...
    tailscale.nix
    ssh-server.nix
    oomd.nix / nix-ld.nix / laptop-power.nix ...
  home/
    base.nix               # username, session vars, programs.home-manager
    fish.nix               # fish + aliases (paths updated!)
    packages-terminal.nix
    packages-programming.nix
    packages-apps.nix
    packages-school.nix
    packages-local.nix     # rmenu (the --impure one)
    llm.nix
  hosts/
    t490s.nix              # defines nixosConfigurations.t490s + homeConfigurations."pebor@t490s"
    t420.nix
    t420-server.nix
```

Files land in `modules/` and are **automatically available** — no `imports` bookkeeping,
no `default.nix` wrapper files (all those 11-line `default.nix` re-exporters disappear).

---

## 4. How the modules look (concrete examples from your config)

### Root `flake.nix` (entire file — it stays hand-written and thin)
```nix
{
  description = "pebor's NixOS + Home Manager configurations";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    flake-parts.url = "github:hercules-ci/flake-parts";
    import-tree.url = "github:vic/import-tree";

    home-manager = { url = "github:nix-community/home-manager"; inputs.nixpkgs.follows = "nixpkgs"; };
    stylix       = { url = "github:nix-community/stylix";       inputs.nixpkgs.follows = "nixpkgs"; };
    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/*";
    mangowc      = { url = "github:mangowm/mango";              inputs.nixpkgs.follows = "nixpkgs"; };
    logseq-nightly = { url = "github:Bad3r/nix-logseq-git-flake"; inputs.nixpkgs.follows = "nixpkgs"; };
    noctalia     = { url = "github:noctalia-dev/noctalia-shell"; inputs.nixpkgs.follows = "nixpkgs"; };
    noctalia-qs  = { url = "github:noctalia-dev/noctalia-qs";    inputs.nixpkgs.follows = "nixpkgs"; };

    # moved from the deleted home-manager flake:
    zen-browser.url = "github:0xc000022070/zen-browser-flake";
    helium       = { url = "github:schembriaiden/helium-browser-nix-flake"; inputs.nixpkgs.follows = "nixpkgs"; };
    helix.url    = "github:helix-editor/helix";
    rose-pine-hyprcursor.url = "github:ndom91/rose-pine-hyprcursor";
    otter-launcher.url = "github:kuokuo123/otter-launcher";

    # dropped (unused): niri, affinity-nix, dms (enable=false), shko (commented)
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
        "https://helix.cachix.org"        # NEW: helix binary cache
        # "https://mango.cachix.org"      # if mango provides one — verify during migration
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
        "nix-logseq-git-flake.cachix.org-1:DSBNW07PSRyCvS926tpIWahb53OIydwwZhsP6LhJNZo="
        "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4="
        # keys for new caches fetched from official sources during migration
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
      settings = { /* ...current common/hypridle.nix... */ };
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

  flake.homeConfigurations."pebor@t490s" = inputs.home-manager.lib.homeManagerConfiguration {
    pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
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
      stylix gaming desktop tailscale
    ];

    networking.hostName = "t490s";
    system.stateVersion = "24.11";

    # host-specific leftovers: lmms overlay, udev rules, oomd, nix-ld,
    # auto-cpufreq, opentabletdriver, logseq+noctalia packages, ...
  };

  flake.modules.homeManager.host-t490s = {
    imports = with inputs.self.modules.homeManager; [
      base fish hyprland stylix
      packages-terminal packages-programming packages-apps
      packages-school packages-local llm
    ];

    home.stateVersion = "24.11";

    # host-specific deltas survive as tiny overrides:
    wayland.windowManager.hyprland.settings.bind = [
      "$mainMod, c, exec, rmenu -c -w 500 -s center -l horizontal -P Calculator"
      "$mainMod, n, exec, rmenu -w 500 -s center -P ..."
      "$mainMod, o, exec, ~/.config/hypr/otter.sh"
    ];
  };
}
```

`t420` / `t420-server` look the same with different import lists
(server: no hyprland/gaming/desktop; instead `ssh-server`; `stateVersion = "25.05"`).

**Adding a 4th host** = one new file in `modules/hosts/` + its hardware file in `hardware/`. Done.

---

## 5. Workflow after the refactor

| Task | Now | After |
|---|---|---|
| System switch | `nh os switch ~/nixos` | same: `nh os switch ~/nixos` (picks host from hostname) |
| HM switch | `nh home switch ~/nixos/home-manager` (+ `--impure`) | `nh home switch ~/nixos -- --impure` (config auto-detected as `pebor@<hostname>`) |
| Update inputs | `nix flake update` ×2 (two locks!) | once: `nix flake update` |
| Add a host | copy+edit ~6 files across hosts/ | one `modules/hosts/x.nix` + `hardware/x.nix` |
| Add a program to all hosts | edit 3 copies of apps.nix | edit `modules/home/packages-apps.nix` once |
| Change a shared setting | edit 3 configuration.nix | edit one feature file |
| Fix hyprland | look in 2 layers, 5+ files | one file: `modules/features/hyprland.nix` |

Fish aliases get updated paths in `modules/home/fish.nix`
(`nxswitch`, `hmswitch` etc. keep working, with `--impure` baked into `hmswitch`).

The `--impure` requirement stays (rmenu via `fetchGit` of a local path).
Optional later: make rmenu a `git+file://` flake input → pure evaluation, at the cost of
`nix flake lock --update-input rmenu` when you want a newer rev.

---

## 6. Caching / build-time improvements (the big wins, ordered)

1. **One flake, one nixpkgs.** Today system and HM pin *different* nixpkgs revs → two package
   universes, double evals/downloads/store. Merging is the single biggest win.
2. **Add `helix.cachix.org`** — turns the biggest source build into a download.
   Also check for an official `mangowc` cache at migration time.
3. **Decide the fate of the `lmms` alpha overlay** — it forces a large Qt rebuild on every
   nixpkgs bump. Keep it only if 1.3.0-alpha is really needed.
4. **Drop unused inputs** (`niri`, `affinity-nix`, `dms` if you don't want DMS): fewer fetches,
   smaller lock, faster evals.
5. `auto-optimise-store = true`, `documentation.man.generateCaches = false` on **all** hosts.
6. Habit change: `nix flake update` rebuilds *the world* by design. Prefer targeted updates:
   `nix flake lock --update-input nixpkgs` (or `nixos`, `home-manager` only) and let the rest stay pinned.
7. Optional, later: `nixpkgs-stable` second input for the server so server bumps don't churn
   the desktop package set (and vice versa).

---

## 7. Answers to your questions

**Is it possible?** Yes — this config is actually a good fit: your `common/` + per-host-delta
layout is already 60% of the dendritic idea, just expressed through file copies.

**Positive outcomes?**
- Duplication → single feature files. Verified win: the 3 copies of packages/config collapse into one.
- The hypridle bug class disappears — one file owns a feature across both layers.
- New hosts become boring (one small file).
- Combined with the flake merge: measurably faster builds and smaller store.

**Simpler?** Structurally yes (fewer files, no copy-paste, no `default.nix` chains,
flake.nix gets *thinner*). One new concept to learn — `flake.modules.<class>.<aspect>` —
and flake-parts error messages can be obtuse while you get used to them. With 3 hosts/1 user
you're at the small end of where this pays off, but you already feel the pain it solves.

**Honest alternative (80/20):** merge the flakes + extract plain shared modules
(`modules/common/*.nix` imported by each host) without flake-parts. ~80% of the dedup,
zero new concepts. You lose: feature files spanning both layers, auto-import, the tidy
host-composition pattern. If you want, this can be phase 1 — the dendritic move builds on
the same flake merge afterwards.

---

## 8. Decisions to make

| # | Question | Recommendation |
|---|----------|----------------|
| 1 | Full dendritic, or 80/20 shared-modules first? | Full dendritic (you asked for it and it fits); the migration plan below works incrementally either way. |
| 2 | Merge both flakes into one root flake? | **Yes** — biggest caching/consistency win. HM stays standalone via `homeConfigurations` outputs. |
| 3 | t420-server HM dir (dead code today) — wire it up or delete? | Wire it up (`pebor@t420-server` output); costs one line in its host file. |
| 4 | Drop unused inputs `niri`, `affinity-nix`, `dms`? | Drop `niri` + `affinity-nix`; keep `dms` only if you plan to use DankMaterialShell. |
| 5 | Keep `determinate` (t490s only)? | Keep as a per-host import; your call — plain nix works too. |
| 6 | Keep the `lmms` 1.3.0-alpha overlay? | Your call — it's the largest recurring local build. |
| 7 | rmenu: keep `--impure`, or `git+file://` flake input? | Keep `--impure` for now (zero workflow change). |

---

## 9. Migration plan (incremental, always buildable)

0. **Commit everything first** (you have ~15 dirty files). Work on a branch.
1. Record baselines: `nixos-rebuild build` + `home-manager build` for all hosts;
   save the closure paths.
2. Add `flake-parts` + `import-tree` to the root flake; move all inputs from
   `home-manager/flake.nix` into it; delete the HM flake + its lock.
   `nix flake lock` → one lock, one nixpkgs.
3. Move hardware files to `hardware/`; create `modules/base/*` (nix, locale, user).
4. Port features one by one, building after each: hyprland (with the hypridle fix),
   fish, packages-*, stylix, greetd, desktop, gaming, ...
5. Create `modules/hosts/*.nix` compositions; wire all 3 `nixosConfigurations`
   + 3 `homeConfigurations`.
6. Compare closures against step-1 baselines (`nix store diff-closures`) —
   goal: system closures identical except intended fixes.
7. Switch on `t490s` (least risky rollback), then the others; delete old
   `hosts/*/home-manager` copies and `home-manager/` dir.
8. Update fish aliases; update README (TODOs mostly resolved by this).

Rollback at any point = `git checkout` + rebuild from the old lock.

### Intended behavior changes (explicit, not accidental)
- hypridle runs **only** as the HM user service with your settings (t490s NixOS-level enable removed).
- Dead HM NixOS-module imports removed.
- Substituters unified across hosts; `helix.cachix.org` added.
- Unused inputs dropped.
