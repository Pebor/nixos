# Desktop PC → NixOS — migration map

> **Status:** research + gaming research complete, nothing changed on the machine yet.
> Target host attr: `desktop` (stub already in the flake).
> Written 2026-11-08, decisions locked the same day. Working document — rewritten
> as decisions land, not appended to.

---

## 0. TL;DR

The PC is a **gaming-first desktop** running Arch + Hyprland, 1943 packages
deep, with three storage devices and ~800 GB used on the OS disk. The mess is
mostly *accumulated*, not *chosen*: four desktop-environment package groups, two
Zen browsers, two Ollama installs, 55 `-debug` packages, a 51 GB orphaned model
store, 26 GB of ROCm that has never touched the GPU, and a 163 GB game library
on the HDD that Steam cannot even see because nothing mounts it.

Target: NixOS with the **CachyOS kernel** (verified: 7.3.1, `CONFIG_NTSYNC=m`,
`CONFIG_SCHED_CLASS_EXT=y`), games on the NVMe, backups on the HDD, and an
install that is rehearsed twice before the Arch install is destroyed.

Migration is ~4 phases and the first one is pure cleanup on Arch — reversible,
no commitment.

**Locked decisions (2026-11-08):** music stack shrunk to a shortlist · Ollama
dropped · Android installed on `/data` · Blender with ROCm/HIP · **all
non-Steam game data deleted** · printing dropped.

---

## 1. Hardware & current system

| | |
|---|---|
| CPU | AMD Ryzen 5 5600X, 6c/12t, Zen 3 (no iGPU) |
| GPU | AMD Radeon RX 6600 (Navi 23), `amdgpu` + RADV |
| RAM | 16 GB, zram 4 GB swap, **no disk swap**, `zswap.enabled=0` in cmdline |
| Display | 1 connected: **DP-1 1920×1080@165 Hz**; DP-2/DP-3/HDMI-A-1 empty |
| Input | Corne v4 (split ergo, Vial), CompX SCOURGEBT mouse, 8BitDo pad rule |
| Net | wired `enp42s0` (in use) + `wlan0` (idle), tailscaled enabled |
| Audio | on-board only, PipeWire + JACK bridge, large LV2 plugin set |
| Boot | GRUB 2.12, EFI, Secure Boot off, no TPM2, no UKI |
| Kernel | `linux-zen` 6.18.13 → target: CachyOS |
| Session | Hyprland 0.54 (hyprlang config) + greetd (`agreety`) |
| Shell | zsh + antidote + starship → NixOS uses **fish** (already in flake) |
| Packages | **1943 installed**, 271 explicit, **192 AUR/foreign**, ~230 orphans |

Nothing is dual-booted. There is no Windows install anywhere on the machine.

---

## 2. Storage today

| Disk | Model | FS | Mounted | Used | Content |
|---|---|---|---|---|---|
| `nvme0n1` 1 TB | Samsung 980 PRO | btrfs | yes | **808 G / 88 %** | `/`, `@home`, `@log`, `@pkg`, `@.snapshots` |
| `sda` 500 G | WD Blue SATA SSD | ext4 | **no** | ~200 G | old `/home` from a previous install |
| `sdb` 1 TB | Seagate 7200 rpm | — | **no** | — | |
| `sdb1` 232 G | | btrfs "Games" | **no** | 163 G | SteamLibrary 124 G + DOOM.Eternal-CODEX 39 G |
| `sdb2` 698 G | | ext4 | **no** | 500 G | backups: `BACKUP NEW SYSTEM` 49 G, `Backup AMD!!` 105 G, `IOSs` 191 G, EpicGames 25 G, anime-game-launcher 36 G, Bannerlord repack 40 G |

Three findings that matter more than the rest:

1. **`sdb1` is never mounted.** `/etc/fstab` has no entry, Steam has only one
   library registered (`libraryfolders.vdf` → only the NVMe path), so Steam
   re-downloaded ~510 GB onto the NVMe and the 163 GB HDD library is dead
   weight. This is the single biggest space bug on the machine.
2. **`sda` is a full ext4 filesystem from an older install** — 27 G Documents,
   65 G Downloads, 76 G Games — mounted by nothing, indexed by nothing.
3. **`sdb2` is ad-hoc copies, not backups.** Five differently-named
   `BACKUP*`/`Backup*` trees with no schedule, no retention, no verification.

Root disk breakdown: `/home` 682 G (Steam 510 G), `/var` 51 G (Ollama),
`/opt` 36 G (ROCm 26 G, Android Studio 3.3 G, NDK 2.4 G), `/usr` 34 G.

---

## 3. Software inventory, by area

**Gaming** — Steam + Proton-GE + UMU + vkd3d-proton + dxvk, gamescope 3.16,
Lutris, Heroic, osu!, PrismLauncher, Modrinth, ATLauncher, r2modman,
CurseForge AppImage, Hytale (Flatpak), `jc141` repack tooling, xone + xpadneo +
8BitDo udev, libratbag. `gamemode` and `mangohud` are **not** installed.

**Dev** — Android Studio + SDK + NDK, Visual Studio Code (+ Code-OSS),
Zed, JDK 8/17, .NET 10, Godot 4.6, Odin, Zig, Rust, Go, Node/pnpm,
Oracle SQL Developer, Typst + Typstudio.

**Music production** — ~50 LV2 plugins (CALF, LSP, x42, drumgizmo, sfizz,
ZynAddSubFX, Helm, Odin2, Cardinal…), guitarix, carla-git, mpd, yoshimi. No DAW
(Ardour/Reaper) installed, no JACK session manager.

**Graphics** — Natron + OpenFX, Inkscape, GIMP, OBS, LibreOffice, Xmind,
AppFlowy, Anki, virtualbox.

**LLM** — Ollama (two installs, two model stores, CPU-only inference).

**Other** — CUPS + hplip (printer idle since Apr 2024), tailscale, sshd,
flatpak, dunst/waybar/wofi/wlogout, browsers ×4 (Brave, Firefox, Zen ×2),
Telegram, Spotify, qBittorrent.

---

## 4. Garbage found — the numbers

Independent of the migration, safe to delete. Order = size.

| What | Size | Why it is garbage |
|---|---|---|
| Ollama model store in `/var/lib/ollama/.ollama` | **51 G** | Orphan from the pre-2024 install. The live store is `~/.ollama` (4.4 G). No service reads it. |
| ROCm toolchain `/opt/rocm` + `ollama-rocm` | **26 G** | Ollama log: `total_vram="0 B"`, `library=cpu`. The GPU path has never worked. *(Blender will re-add a much smaller HIP subset.)* |
| Non-Steam game data | **~180 G** | **Decided: delete all of it.** `sdb1`: DOOM.Eternal-CODEX 39 G. `sdb2`: anime-game-launcher 36 G, Bannerlord repack 40 G, EpicGames 25 G. Nothing here is played. |
| Dead Steam library on `sdb1` | **124 G** | Not garbage, but invisible to Steam (nothing mounts the partition). |
| 4 desktop-environment package groups | ~4–6 G | `gnome`, `plasma`/`kde-applications`, `xfce4`, `lxqt`; only Hyprland is used. |
| 55 `-debug` packages | ~2–4 G | AUR debug-symbol splits pulled in by accident (`gcc14-libs`, `clang16/18/19`, `openssl-1.1`…). |
| VirtualBox + VM | **9.8 G** | One VM, "NixOS 23.05", plus a `vboxhost` DKMS module. |
| Duplicate apps | ~2 G | `zen-browser-bin` **and** `zen-browser-optimized-bin`; `visual-studio-code-bin` **and** Code-OSS; Ollama as `/usr/local/bin/ollama` **and** package. |
| ~230 orphan packages | ~2 G | `pacman -Qtdq` — leftover makedeps from years of AUR builds. |
| CUPS + hplip + queue | — | DeskJet 3630 idle since 2024-04. *(Decided: drop.)* |
| CurseForge AppImage in `/usr/local/bin` | 136 M | Unmanaged, manual updates. |

Immediately reclaimable on the NVMe: **~90 G**. On the HDD: **~180 G** (the
non-Steam game data). That is the space the new backup scheme gets to use.

---

## 5. Hacks that must not survive

Every one of these is dead weight or a workaround for a problem that does not
exist on NixOS. Listed so they get *deliberately* not ported.

| Hack | Where | Why it dies |
|---|---|---|
| `WLR_DRM_NO_ATOMIC=1` | Hyprland `env` | Workaround for old GCN cards; Navi 23 has working atomic modesetting. Costs VRR and some multi-monitor paths. |
| `options amdgpu si_support=1 cik_support=1` + `radeon si_support=0 cik_support=0` | `/etc/modprobe.d/10-amdgpu.conf` | Southern-Islands / Sea-Islands toggles for 2012-era GPUs. |
| `killxdg.sh` **and** `scripts/xhdp_fix.sh` | `hyprland.conf` `exec-once` | Two racing scripts that `killall` and restart XDG portals. NixOS portals are module-managed. |
| `zswap.enabled=0` + zram | cmdline + `zram-generator` | Two competing swap schemes; `zramSwap` is a NixOS option. |
| NetworkManager **+** systemd-networkd **+** iwd all enabled | systemd | Three managers, one of them actually routing. |
| `swallow_regex=Alacritty`, `scratchpadterm.sh` | Hyprland | References `alacritty`, not installed. Dead since the kitty switch. |
| `bind=SUPER,14,workspace,6` and `SUPER,15,workspace,6` | Hyprland | Copy/paste bug — both keys target workspace 6, 5 unreachable. |
| `wofi --show drun -o DP-3` | Hyprland | `DP-3` is disconnected. |
| `import-gsettings` | Hyprland | Not present; portal/env plumbing belongs to the NixOS module. |
| `droidcam` + `v4l2loopback-dc` DKMS | system | Phone-as-webcam; he already has the `phone-mic` PipeWire script, and DKMS is a rebuild hazard on NixOS. |
| `xone` DKMS with 3 versions added, 1 installed | dkms | `hardware.xone` is a NixOS option. |
| `ollama.service` hand-written unit running `/usr/local/bin/ollama` | `/etc/systemd/system` | Binary outside the package manager. |
| `greetd` with `agreety` greeter, `regreet` installed | greetd | Text greeter while the graphical one sits unused. |

---

## 6. Target design

### 6.1 Flake layout — what already exists, what to add

The `desktop` host attr already exists and **evaluates green**
(`.#nixosConfigurations.desktop.config.system.build.toplevel.drvPath` resolves
to a store path):

```
modules/hosts/desktop.nix     imports: system, user, hyprland, niri, greetd,
                              stylix, gaming, desktop, tailscale, build-client,
                              nix-ld, oomd
hardware/desktop.nix          placeholder — must be replaced with real hardware
modules/features/gaming.nix   3 lines
modules/features/desktop.nix  pipewire, graphics, fonts, printing, kdeconnect
```

Gaps to close before install:

| Gap | Fix |
|---|---|
| `hardware/desktop.nix` is a dummy (`/dev/disk/by-label/nixos`, ext4) | `nixos-generate-config` from the live ISO + AMD bits from §6.4 |
| `gaming.nix` is a stub | full stack from §6.3 |
| no kernel module | `modules/features/cachyos-kernel.nix` (§6.2) |
| no gaming tuning | `modules/features/gaming-tuning.nix` (sysctl, ntsync, scx, gamemode, mangohud) |
| no storage concept | `modules/features/storage-desktop.nix` (§6.8) |
| `desktop.nix` has FIXMEs | `stateVersion` → `26.11` (flake tracks unstable 26.11pre) |
| printing enabled in `desktop.nix` | drop `services.printing` (decided) |

Note: `programs.steam.enable` **already sets** `hardware.graphics.enable32Bit`
itself — 32-bit is not a gap, it is automatic. (Checked in the steam module: it
forces `enable = true; enable32Bit = true;`, plus `hardware.steam-hardware.enable`
for controller udev rules and 32-bit PipeWire.)

### 6.2 Kernel — CachyOS

Verified against the pinned nixpkgs: **not in nixpkgs**, available through
`chaotic-nyx`:

```
input:  github:chaotic-cx/nyx/nyxpkgs-unstable      # branch, not the default one
module: chaotic.nixosModules.default                # overlay + binary cache + registry
result: pkgs.linuxPackages_cachyos-lto.kernel.version = 7.3.1
```

Variants: `-bore` (BORE scheduler compiled in), `-eevdf` (mainline scheduler),
`-lto` (ThinLTO, generic x86-64), `-lto-znver4` (**wrong for Zen 3**), plus
`-rc`, `-lts`, `-hardened`, `-server`, `-bmq`, `-rt-bore`.

Verified kernel config of the `-lto` build (`config-nix/cachyos-lto.x86_64-linux.nix`):

| Symbol | Value | Why it matters |
|---|---|---|
| `CONFIG_NTSYNC` | `m` | NT sync primitives in-kernel → Wine/Proton drops the wineserver round-trips |
| `CONFIG_SCHED_CLASS_EXT` | `y` | sched_ext: swap the whole scheduler at runtime (§6.3) |

**Important:** nixpkgs' own kernels do **not** enable `CONFIG_NTSYNC`
(`common-config.nix` has no entry for it). So ntsync is a concrete reason to
take the CachyOS kernel, and it silently does nothing on `linux_latest`.

Operational rules:

- Add `chaotic.nixosModules.default` — it wires the cache
  (`https://nyx-cache.chaotic.cx/`) automatically. Without it the kernel builds
  from source for hours.
- Chaotic does **not** follow our nixpkgs (same rule as helix/logseq inputs).
- Fallback if chaotic breaks: `boot.kernelPackages = pkgs.linuxPackages_zen`
  (what Arch runs today) — one line, nothing else depends on CachyOS.
- Scheduler variants matter less here: with `sched_ext` the scheduler is
  replaced at runtime anyway, so `-lto` is the sensible base.

### 6.3 Gaming — the stack, verified against nixpkgs

**What the flake must enable** (every name checked to exist in the pinned
nixpkgs):

```nix
programs.steam = {
  enable = true;
  gamescopeSession.enable = true;            # also enables programs.gamescope
  protontricks.enable = true;
  extest.enable = true;                      # X11→uinput for Steam Input on Wayland
  extraCompatPackages = [ pkgs.proton-ge-bin ];
  extraPackages = [ pkgs.mangohud pkgs.goverlay ];   # must be inside the FHS env
  remotePlay.openFirewall = true;
};

programs.gamemode.enable = true;             # renice capability is on by default
hardware.xone.enable = true;                 # Xbox dongle/controller
hardware.xpadneo.enable = true;              # Xbox BT gamepads
```

Launchers / extras (all present in nixpkgs): `heroic`, `lutris`, `osu-lazer`,
`prismlauncher`, `modrinth-app`, `r2modman`, `atlauncher`, `umu-launcher`,
`vkbasalt`, `steamtinkerlaunch`, `protonup-ng`, `lact`.

Not in nixpkgs: Hytale launcher (Flatpak today) and CurseForge (AppImage).
Decision: Hytale keeps Flatpak; CurseForge only if still used.

**Verified tuning levers** — each is a real option in our pinned nixpkgs or a
documented kernel/Mesa knob, not a forum myth:

| Lever | Config | Effect | Risk |
|---|---|---|---|
| **ntsync** | `boot.kernelModules = [ "ntsync" ]` + udev `KERNEL=="ntsync", MODE="0666"` | Wine/Proton waits stop bouncing through wineserver; the biggest frame-time win in modern titles | none on a single-user box |
| **sched_ext** | `services.scx-loader.enable = true; services.scx-loader.config.default_sched = "scx_lavd";` | swappable BPF scheduler tuned for low latency; `scx_lavd` for games, `scx_bpfland` for desktop | needs kernel ≥ 6.12 (module asserts it); a bad scheduler is one `systemctl restart` away |
| **split-lock mitigation off** | `boot.kernel.sysctl."kernel.split_lock_mitigate" = 0;` | removes the "misery mode" delay penalty some Unity/Unreal titles hit | none on a personal machine |
| **`vm.max_map_count`** | `= 2147483642` (SteamOS value; NixOS default 1048576) | stability of large-world titles | none |
| **`vm.swappiness`** | `= 100` with zram | zram is a fast device; swapping into it early beats dropping page cache | slightly more CPU under pressure |
| **`kernel.nmi_watchdog`** | `= 0` | removes a periodic perf-counter stall | loses hard-lockup detection (irrelevant here) |
| **`zramSwap`** | `zramSwap.enable = true; zramSwap.algorithm = "zstd";` | replaces the `zram-generator` + `zswap.enabled=0` hack | none |
| **Mesa shader cache** | `MESA_SHADER_CACHE_MAX_SIZE = "12G"` | default 1 G evicts big-title caches → re-compile stutter | disk space only |
| **GameMode** | `programs.gamemode.enable` (+ optional `settings.general.renice = 10`) | per-session niceness/ioprio; it already disables split-lock mitigation | none |
| **Hyprland tearing** | `general:allow_tearing = true` + `windowrule = immediate, class:^(cs2)$` | lowest input latency in competitive shooters | tearing is visible; fullscreen games only |
| **VRR** | `misc:vrr = 1` | smooth 165 Hz without tearing | only if the panel does FreeSync — check the OSD first |
| **LACT** | `services.lact.enable = true` | fan curve, power limit, undervolt for the RX 6600 | a bad curve is recoverable by reboot |

**Explicitly rejected** (copy-paste from gaming configs that does not apply):

- `PROTON_ENABLE_NVAPI=1` — NVIDIA-only.
- `ENABLE_HDR_WSI` / `DXVK_HDR` — the panel is 1080p SDR.
- `__GL_SHADER_DISK_CACHE*` — NVIDIA-only.
- `RADV_PERFTEST=aco` — ACO is the default compiler since Mesa 20.
- `mesa_glthread=true` — default on for radeonsi.
- `PROTON_USE_NTSYNC=1` — Proton 10/GE enable it automatically when
  `/dev/ntsync` exists; a global override can break older Proton versions.
- `kernel.sched_bore=1` sysctl without the BORE kernel — a no-op that looks
  like a tweak.

**What actually moves the needle on this box**, in order: games on the NVMe
(§6.8), ntsync, shader cache, scheduler, then everything else. No sysctl makes
an RX 6600 faster than moving the library off SATA.

### 6.4 Graphics / Blender

- `hardware.graphics.enable = true` (RADV default; no `amdvlk`, no `mesa-git`
  unless a specific title needs it — chaotic can supply `mesa-git` if it does).
- Blender GPU rendering: the package takes `rocmSupport ? config.rocmSupport`,
  so `nixpkgs.config.rocmSupport = true` gives a HIP-enabled Blender built
  against ROCm. That replaces the 26 GB hand-installed `/opt/rocm` with
  store-managed HIP packages — much smaller, only the runtime is pulled.
- Natron/OpenFX/Inkscape/GIMP/OBS/Blender all exist in nixpkgs.
- `lact` covers fan/power/undervolt; `hardware.corectrl` exists as an
  alternative but needs more polkit wiring.

### 6.5 Audio

Decided: **shrink**, not drop. Keep the signal chain that is actually used —
PipeWire + `pipewire-jack`, guitarix, carla, sfizz, drumgizmo, LSP, Calf — and
drop the remaining ~40 LV2 packages from the system profile (re-add per project
or via `nix shell`).

Gaming audio: `services.pipewire.extraConfig` with a smaller quantum only if
there is audible latency; the default is fine for games and a tight quantum
costs CPU.

### 6.6 Dev toolchains

Android is the heavy one — on NixOS it is `android-studio` plus `androidenv`
(SDK/NDK as derivations, not `/opt` downloads), installed to `/data`.
Everything else maps 1:1 into `modules/home/packages-programming.nix`, which
already covers Rust, Go, Kotlin, Nim, Zig, Typst, Python, SBCL. To add: .NET,
Godot, Odin, JDK 8/17, Android SDK.

### 6.7 System services & network

- **One** network manager (NetworkManager). Drop `systemd-networkd` and `iwd`.
- `tailscale`, `sshd` — same as the fleet.
- `fwupd` yes; `printing` no.
- `build-client` + `nix-ld` already imported: the t490s builds and serves the
  binary cache for the fleet, so the desktop substitutes instead of compiling.
- `oomd` stays (16 GB + games).

### 6.8 Storage layout & backups

```
NVMe 1 TB   system + home + GAMES      btrfs, subvols:
                                      @      60 G   /
                                      @home  250 G  /home
                                      @games rest   /games   (Steam + launchers)
                                      @snapshots    (not mounted)
SSD 500 GB  hot data                   /data — documents, photos, videos, VMs,
                                       downloads, project archives, Android SDK
HDD 1 TB    cold + backups             btrbk snapshots of @home, restic repo,
                                       ISOs, media archive
```

Rationale: the fastest device holds what loading time depends on; the SSD holds
what is opened daily; the HDD is the only device whose failure loses nothing
irreproducible.

Rules that come with it:

- Games get their **own subvolume** so snapshots of `/` do not multiply game
  data and backups skip it explicitly.
- Steam layout on `@games`: library folder + `compatdata` + `shadercache` on the
  same subvolume. **Move `compatdata` with the library or games lose their
  saves** — Proton prefixes live there.
- No swap partition; `zramSwap` (16 GB is plenty, hibernation is pointless on a
  desktop).
- `/` snapshots: `services.snapper` (nice-to-have — NixOS generations already
  roll the system back), `/home` → HDD via `btrbk`.
- `noatime,compress=zstd:1,discard=async` on btrfs; HDD never in the games path.
- `/boot`: one ESP, **systemd-boot** with generation entries — replaces hand-run
  `grub-install`/`grub-mkconfig` and `efibootmgr` editing, and makes every
  generation a boot entry (the rollback mechanism NixOS expects).

---

## 7. Migration phases

No step can lose data, and the boring parts happen while Arch still runs fine.

### Phase 0 — clean up Arch, prove what is where (no commitment)

1. Delete the reclaimable garbage from §4: orphaned Ollama store, `/opt/rocm` +
   `ollama-rocm`, `-debug` packages, duplicate apps, 230 orphans, VirtualBox VM,
   CUPS stack.
2. **Delete all non-Steam game data**: `sdb1/DOOM.Eternal-CODEX`,
   `sdb2/{anime-game-launcher,EpicGames,Mount.and.Blade.II…}`, `~/Games`,
   `~/.local/share/{jc141,lutris,atlauncher}` leftovers.
3. Mount `sdb1`, let Steam re-register the existing library; decide whether the
   510 G NVMe library stays (it moves to `@games` at cutover anyway).
4. Produce a **uniqueness report for `sda`**: which paths exist only there
   (name + size + mtime comparison against `~` and `sdb2` — no file contents).
5. Snapshot the config surface: `pacman -Qqet`, `systemctl list-unit-files`,
   `~/.config` tree, Hyprland/waybar/kitty configs.

Exit criteria: NVMe under 70 %, `sda` content proven redundant or copied to
`sdb2`, non-Steam game data gone, all three disks mounted intentionally.

### Phase 1 — build the config green, on the t490s

1. Write the new modules (§6.1–6.8 + tuning from §6.3).
2. `nix build` the whole `desktop` closure **on the t490s** (builder + cache) —
   full evaluation plus a real build, so nothing is discovered on install day.
3. Boot it in a QEMU/`vmtest`-style VM to check the session, fonts, bar and
   keybinds before any disk is touched.

Exit criteria: `desktop` closure builds; VM boots to a working Hyprland; the
eval prints a `cachyos` kernel version and lists steam/mangohud/gamemode.

### Phase 2 — install NixOS next to Arch (rehearsal, reversible)

1. Free `sda` (only after the Phase 0 report).
2. Partition `sda` with disko (`hardware/desktop-disko.nix`), install with its
   own ESP; NVMe ESP + Arch stay untouched.
3. Firmware boot menu gets a second entry — Arch remains selectable.
4. **Playtest for real:** Steam library path, Proton + GE, gamescope, controller,
   ntsync active, audio latency, 165 Hz + tearing/VRR, suspend, Discord voice.

Exit criteria: a week of real gaming on NixOS with no reason to boot Arch.

### Phase 3 — cutover

1. Final data sync: `~` → SSD `/data`, games → `@games`, caches left behind.
2. Reinstall NixOS on the NVMe with the final layout (§6.8); disko targets the
   NVMe; `sda` becomes `/data`.
3. Boot the new system, verify, then wipe the old Arch partition on `sda` (or
   keep it a month as emergency — it costs nothing).
4. After a clean week: remove the Arch boot entry.

Rollback at every step: the previous disk is still there, still bootable.

### Phase 4 — finish

- btrbk/restic schedule to the HDD, **restore test**.
- Secrets: Vaultwarden/Bitwarden, SSH keys, GPG.
- Optional: Hermes client so the desktop reaches the agent like the t14 does.

---

## 8. Decisions

| # | Question | Decision (2026-11-08) |
|---|---|---|
| 1 | Music/LV2 stack | **Shrink** to PipeWire + JACK + guitarix, carla, sfizz, drumgizmo, LSP, Calf |
| 2 | Ollama on the desktop | **Drop** (CPU-only, 16 GB RAM; `services.ollama` can be added later) |
| 3 | Android toolchain | **Install** on `/data`, via androidenv |
| 4 | Blender / ROCm | **Yes**, `nixpkgs.config.rocmSupport = true` (HIP Blender) |
| 5 | Non-Steam game data | **Delete everything** — Steam only |
| 6 | Printing | **Drop** CUPS |

Still open (answered by the machine, not by him):

- Does the 165 Hz panel do FreeSync? → decides `misc:vrr`.
- Hibernate? → assumed no (zram only).

---

## 9. Unknowns

- Which of the ~45 Steam titles he still plays (no playtime data readable
  without reading personal config).
- Whether CurseForge is still used at all.

---

## 10. Verification checklist (per phase)

**Phase 0** — `df -h` before/after, `pacman -Qtdq` empty, all three disks in
`lsblk` with intended mounts, `sda` report written.

**Phase 1** — `nix build .#nixosConfigurations.desktop.config.system.build.toplevel`
exits 0 on the t490s; kernel eval prints `7.3.x-cachyos`; package eval lists
steam/mangohud/goverlay/proton-ge/gamemode.

**Phase 2** — `bootctl list` shows two entries; `hyprctl monitors` shows 165 Hz;
`lsmod | grep ntsync`; `systemctl status scx_loader` active with `scx_lavd`; a
Proton title runs; controller pairs; `pactl info` shows PipeWire; a
`nixos-rebuild switch` rollback works.

**Phase 3** — `df -h` shows the intended split; `btrfs subvolume list` matches
§6.8; Steam finds the library on `@games`; `btrbk list` shows a snapshot;
restore one file from it.

**Phase 4** — restic check passes, secrets present, one full week without
booting Arch.

---

## 11. Sources (checked 2026-11-08)

- [NixOS Wiki — Gaming](https://wiki.nixos.org/wiki/Gaming) — split-lock
  mitigation, `vm.max_map_count`, GameMode.
- [Chaotic-Nyx docs](https://www.nyx.chaotic.cx/) — flake input
  (`nyxpkgs-unstable`), `nixosModules.default`, binary cache, cache
  troubleshooting.
- [sched-ext scx INSTALL](https://github.com/sched-ext/scx/blob/main/INSTALL.md)
  — `scx` in nixpkgs, kernel ≥ 6.12.
- [Hyprland Wiki — Tearing](https://wiki.hypr.land/configuring/extra/tearing/)
  — `allow_tearing` + `immediate` window rule and its caveats.
- [kernel.org — ntsync driver](https://docs.kernel.org/6.14/userspace-api/ntsync.html)
  — what the driver is for.
- [CachyOS — kernel features](https://wiki.cachyos.org/features/kernel/) and
  [linux-cachyos README](https://github.com/CachyOS/linux-cachyos) — PREEMPT,
  1000 Hz, EEVDF vs BORE, ThinLTO, sched_ext, NTSYNC.
- nixpkgs sources read directly (pinned rev): `programs/steam.nix`,
  `programs/gamemode.nix`, `services/scheduling/scx-loader.nix`,
  `services/misc/ananicy.nix`, `services/hardware/lact.nix`,
  `hardware/graphics.nix`, `pkgs/os-specific/linux/kernel/common-config.nix`,
  chaotic `pkgs/linux-cachyos/config-nix/cachyos-lto.x86_64-linux.nix`.
