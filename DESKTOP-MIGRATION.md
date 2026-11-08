# Desktop PC → NixOS — migration map

> **Status:** research complete, nothing changed on the machine yet.
> Target host attr: `desktop` (stub already in the flake).
> Written 2026-11-08. This is a working document — it gets rewritten as
> decisions land, not appended to.

---

## 0. TL;DR

The PC is a **gaming-first desktop** running Arch + Hyprland, 1943 packages
deep, with three storage devices and ~800 GB used on the OS disk. The mess is
mostly *accumulated*, not *chosen*: five desktop environments, two Zen
browsers, two Ollama installs, 55 `-debug` packages, a 51 GB orphaned model
store, 26 GB of ROCm that has never touched the GPU, and a 163 GB game library
on the HDD that Steam cannot even see because nothing mounts it.

Target: NixOS with the **CachyOS kernel** (verified available, 7.3.1), games on
the NVMe, backups on the HDD, and an install that is rehearsed twice before the
Arch install is destroyed.

Migration is ~4 phases and the first one is pure cleanup on Arch — reversible,
no commitment.

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
   65 G Downloads, 76 G Games — mounted by nothing, indexed by nothing. Its
   uniqueness is unknown (see §7 Phase 0).
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
Zed, JetBrains-free (JDK 8/17), .NET 10, Godot 4.6, Odin, Zig, Rust, Go, Node/pnpm,
Oracle SQL Developer, Typst + Typstudio.

**Music production** — ~50 LV2 plugins (CALF, LSP, x42, drumgizmo, sfizz,
ZynAddSubFX, Helm, Odin2, Cardinal…), guitarix, carla-git, mpd, yoshimi. No DAW
(Ardour/Reaper) installed, no JACK session manager.

**Graphics** — Natron + OpenFX, Inkscape, GIMP, OBS, LibreOffice, Xmind,
AppFlowy, Anki, virtualbox.

**LLM** — Ollama (two installs, two model stores, CPU-only inference).

**Other** — CUPS + hplip (printer idle since Apr 2024), tailscale, sshd,
flatpak, dunst/waybar/wofi/wlogout, Chromium-family browsers ×3
(Brave, Firefox, Zen ×2), Telegram, Spotify, qBittorrent.

---

## 4. Garbage found — the numbers

These are safe to delete and are independent of the migration. Order = size.

| What | Size | Why it is garbage |
|---|---|---|
| Ollama model store in `/var/lib/ollama/.ollama` | **51 G** | Orphan from the pre-2024 install. The live store is `~/.ollama` (4.4 G, 9 models). No service reads it. |
| ROCm toolchain `/opt/rocm` + `ollama-rocm` | **26 G** | Ollama log: `total_vram="0 B"`, `library=cpu`. The GPU path has never worked. |
| Steam library on NVMe | **510 G** | Not garbage itself, but it should live on the games disk, not on the system disk. |
| Dead game data on `sdb1` | **163 G** | Invisible to Steam (nothing mounts the partition). |
| 4 desktop-environment package groups | ~4–6 G | `gnome`, `plasma`/`kde-applications`, `xfce4`, `lxqt` groups installed; only Hyprland is used. |
| 55 `-debug` packages | ~2–4 G | AUR debug-symbol splits pulled in by accident (`*-debug`, `gcc14-libs`, `clang16/18/19`, `openssl-1.1`…). |
| VirtualBox + VM | **9.8 G** | One VM, "NixOS 23.05", plus a `vboxhost` DKMS module against `linux-zen`. |
| Duplicate apps | ~2 G | `zen-browser-bin` **and** `zen-browser-optimized-bin`; `visual-studio-code-bin` **and** Code-OSS; Ollama as `/usr/local/bin/ollama` **and** package. |
| ~230 orphan packages | ~2 G | `pacman -Qtdq` — leftover makedeps from years of AUR builds. |
| CUPS + hplip + queue | — | DeskJet 3630 idle since 2024-04; no printer on the machine. |
| CurseForge AppImage in `/usr/local/bin` | 136 M | Unmanaged AppImage, manual updates. |

Total immediately reclaimable on the NVMe: **~80–90 G** without touching a
single game or document.

---

## 5. Hacks that must not survive

Every one of these is dead weight or a workaround for a problem that does not
exist on NixOS. They are listed so they get *deliberately* not ported.

| Hack | Where | Why it dies |
|---|---|---|
| `WLR_DRM_NO_ATOMIC=1` | Hyprland `env` | Workaround for old GCN cards; Navi 23 has working atomic modesetting. Costs VRR and some multi-monitor paths. |
| `options amdgpu si_support=1 cik_support=1` + `radeon si_support=0 cik_support=0` | `/etc/modprobe.d/10-amdgpu.conf` | Southern-Islands / Sea-Islands toggles for 2012-era GPUs. Irrelevant on Navi 23. |
| `killxdg.sh` **and** `scripts/xhdp_fix.sh` | `hyprland.conf` `exec-once` | Two racing scripts that `killall` and restart XDG portals. Classic symptom of a half-broken portal package; NixOS portals are module-managed. |
| `zswap.enabled=0` + zram | cmdline + `zram-generator` | Two competing swap schemes; `zramSwap` is a first-class NixOS option. |
| NetworkManager **+** systemd-networkd **+** iwd all enabled | systemd | Three managers, one of them actually routing. NixOS picks one via config. |
| `swallow_regex=Alacritty`, `scratchpadterm.sh` | Hyprland | References `alacritty`, which is not installed. Dead since the kitty switch. |
| `bind=SUPER,14,workspace,6` and `SUPER,15,workspace,6` | Hyprland | Copy/paste bug — both keys target workspace 6, 5 is unreachable. |
| `wofi --show drun -o DP-3` | Hyprland | `DP-3` is disconnected; output override is meaningless. |
| `killall`-based portal restarts + `import-gsettings` | Hyprland | `import-gsettings` not present; portal/env plumbing is owned by the NixOS module. |
| `droidcam` + `v4l2loopback-dc` DKMS | system | Only needed for phone-as-webcam; he already has the `phone-mic` PipeWire script, and DKMS modules are a rebuild hazard on NixOS. |
| `xone` DKMS with 3 versions added, 1 installed | dkms | `hardware.xone` exists as a NixOS option; manual DKMS is unnecessary. |
| CUPS, hplip, avahi | system | Printing stack with no printer. |
| `ollama.service` hand-written unit running `/usr/local/bin/ollama` | `/etc/systemd/system` | Binary outside the package manager; NixOS has `services.ollama`. |
| `greetd` with `agreety` greeter, `regreet` installed | greetd | Falls back to a text greeter while the graphical one sits unused. |

---

## 6. Target design

### 6.1 Flake layout — what already exists, what to add

The `desktop` host attr already exists and **evaluates green**
(`.#nixosConfigurations.desktop.config.system.build.toplevel.drvPath` resolves):

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
| `hardware/desktop.nix` is a dummy (`/dev/disk/by-label/nixos`, ext4) | `nixos-generate-config` from the live ISO, plus AMD entries from §6.4 |
| `gaming.nix` is a stub | full stack from §6.3 |
| `hardware.graphics.enable32Bit` **not set** | required for Steam/DXVK/Wine 32-bit — currently a silent breakage for every game |
| no kernel module | new `modules/features/cachyos-kernel.nix` (§6.2) |
| no storage concept | new `modules/features/storage-desktop.nix` (§6.8) |
| `desktop.nix` FIXMEs | `stateVersion` → `26.11` (flake tracks unstable 26.11pre) |
| no backup concept | btrbk or restic to the HDD (§6.8) |

New feature modules, one concern each (matching the existing dendritic style):
`cachyos-kernel.nix`, `gaming.nix` (rewrite), `storage-desktop.nix`,
`pro-audio.nix` (optional), `android.nix` (optional), `llm-desktop.nix` (optional).

### 6.2 Kernel — CachyOS

Verified against the pinned nixpkgs: **not in nixpkgs**, available through
`chaotic-nyx` (third-party flake, overlay + its own binary cache):

```
pkgs.linuxPackages_cachyos-lto         → 7.3.1
variants: -bore, -eevdf, -bmq, -lto, -lts, -rc, -gcc, -hardened, -rt-bore,
          -server, -lto-znver4
```

Notes:

- `zenver4` variant is **wrong for this CPU** (5600X is Zen 3) — use the plain
  `-lto` or `-bore` build.
- Add `chaotic.nixosModules.nyx-cache` (`https://cache.chaotic.cx`) or the
  kernel builds from source for hours.
- Chaotic follows its own nixpkgs pin; it does **not** follow ours (same rule
  as the helix/logseq inputs). Keep it a separate input and do not let it drag
  nixpkgs.
- Fallback if chaotic breaks: `pkgs.linuxPackages_zen` (what Arch runs now)
  swapped in one line; the config must not depend on anything CachyOS-specific.
- CachyOS-only extras worth taking with it: `ananicy-rules-cachyos`,
  `scx` scheduler modules (optional), and `vm.max_map_count` bump for Proton.

### 6.3 Gaming stack — Arch → NixOS mapping

Everything below was verified to exist in the pinned nixpkgs.

| Arch | NixOS |
|---|---|
| `steam` + `proton-ge-custom-bin` + `umu-launcher` + `vkd3d-proton-bin` | `programs.steam.enable`, `programs.steam.extraCompatPackages = [ proton-ge-bin ]` |
| `gamescope` | `programs.gamescope.enable`, `programs.steam.gamescopeSession.enable` |
| — (`gamemode` missing) | `programs.gamemode.enable` |
| — (`mangohud` missing) | `pkgs.mangohud` + `pkgs.goverlay` |
| `lutris`, `heroic`, `osu-lazer-bin`, `prismlauncher`, `modrinth-app`, `r2modman`, `atlauncher` | same names in nixpkgs |
| Hytale Flatpak | **decision needed** — no nixpkgs package; Flatpak stays enabled or a manual AppImage |
| `xone-dkms`, `xpadneo-dkms`, `game-devices-udev`, `99-8bitdo.rules` | `hardware.xone.enable`, `hardware.xpadneo.enable`, `services.udev.packages` |
| `lib32-vulkan-radeon`, `mesa`, `dxvk-bin` | `hardware.graphics.enable32Bit = true` + `programs.steam` |
| `jc141` repacks / CODEX dumps | not portable as packages; the game trees move with the data and are launched by hand |

Gaming-specific system settings to carry deliberately (all currently missing):

- `vm.max_map_count` high enough for modern Proton titles.
- `zramSwap` instead of the current zram-generator + zswap-off pair.
- VRR/tearing: `misc { allow_tearing }` exists in Hyprland today; check whether
  the 165 Hz panel does FreeSync before porting it.
- Per-game launch options currently in use (`gamescope -W 1920 -H 1080 -r 200`,
  `-sdlaudiodriver pipewire`, one `WINEDLLOVERRIDES`) are re-entered by hand —
  Steam's `localconfig.vdf` is not migrated by Nix.

**Not decided by me:** whether the ~160 GB of non-Steam game data (repacks,
Epic copies on `sdb2`, DOOM dump) is worth carrying at all. See §8.

### 6.4 Graphics / Blender

- `hardware.graphics.enable = true` + `enable32Bit = true`; RADV is default,
  no `amdvlk`/`mesa-git` needed (chaotic's `mesa-git` module exists — do not
  take it without a reason).
- Blender on this card needs **HIP/ROCm** for GPU rendering; without it Blender
  renders on CPU. That is a real decision: `rocmPackages.clr` + `hip` is a few
  GB and needs `HSA_OVERRIDE_GFX_VERSION` for Navi 23 on some versions.
- Natron/OpenFX/Inkscape/GIMP/OBS/Blender all exist in nixpkgs.

### 6.5 Audio

Current: PipeWire + `pipewire-jack` + ~50 LV2 plugins, guitarix, carla, mpd.
No DAW installed. `pro-audio` package set exists in nixpkgs but it is large and
most of it is redundant with `pipewire`'s JACK bridge.

Decision needed: keep the music-production stack, shrink it to a named subset,
or drop it (in which case `pipewire-jack` is the only thing worth keeping).

### 6.6 Dev toolchains

Android (Studio + SDK + NDK) is the heavy one — on NixOS it is
`android-studio` + `androidenv` (SDK/NDK as derivations, not manual downloads).
The rest maps 1:1 (see `modules/home/packages-programming.nix`, which already
covers most of it: Rust, Go, Kotlin, Nim, Zig, Typst, Python, Nimble, SBCL…).

Missing from the flake today: .NET 10, Godot, Odin, JDK 8/17, Android SDK.

### 6.7 System services & network

- **One** network manager (NetworkManager — he switches between wired and WiFi).
  Kill systemd-networkd and iwd unless WiFi decides it needs iwd (it does not;
  NetworkManager handles `wpa_supplicant` fine).
- `tailscale` — already a feature module, same as the fleet.
- `sshd` — keep (matches fleet practice; key-only).
- `fwupd` `cups` — fwupd yes, printing no.
- `build-client` + `nix-ld` already imported: the t490s is the builder + binary
  cache for the fleet, so the desktop gets the same fast-substitute path. Keep it.
- `oomd` — the box has 16 GB and games; keep.

### 6.8 Storage layout & backups

Proposed target (three devices, three roles):

```
NVMe 1 TB   system + home + GAMES      btrfs, subvols:
                                      @      60 G   /
                                      @home  250 G  /home
                                      @games rest   /games   (Steam + launchers)
                                      @snapshots    (not mounted)
SSD 500 GB  hot data                   /data — documents, photos, videos, VMs,
                                       downloads, project archives
HDD 1 TB    cold + backups             btrbk snapshots of @home → daily/weekly,
                                       restic repo, ISOs, media archive
```

Rationale: the fastest device holds what loading time depends on (games) and
the OS; the SSD holds what he opens daily; the HDD is the only device whose
failure loses nothing that is not reproducible.

Rules that come with it:

- Games get their **own subvolume** so btrfs snapshots of `/` do not multiply
  game data, and so backups skip them explicitly.
- No swap partition; `zramSwap` (16 GB RAM + zram is enough for this workload,
  and hibernation on a desktop is pointless).
- Snapshots: `services.snapper` for `/` (or none — NixOS generations already
  give system rollback), `btrbk` for `/home` → HDD.
- `discard=async`, `compress=zstd:1`, `noatime` on all btrfs mounts.
- The HDD is **not** in the games path, ever (7200 rpm SATA = stutter).
- `/boot`: one ESP on the NVMe, systemd-boot with generation entries (drops hand-run
  `grub-install`/`grub-mkconfig` and `efibootmgr` editing; every generation
  becomes a boot entry, which is exactly the rollback mechanism NixOS expects).

---

## 7. Migration phases

The point of the phasing is that **no step can lose data**, and the boring
parts happen while the machine still runs Arch fine.

### Phase 0 — clean up Arch, prove what is where (no commitment)

1. Delete the reclaimable garbage from §4 that is obviously dead: orphaned
   Ollama store, `/opt/rocm` + `ollama-rocm`, `-debug` packages, one of each
   duplicate app, 230 orphans, VirtualBox VM.
2. Mount `sdb1` and let Steam re-register the existing library; move the NVMe
   library there **or** decide the library moves to the new `@games` later.
3. Produce a **uniqueness report for `sda`**: which paths exist only there
   (name + size + mtime comparison against `~` and `sdb2`; no file contents
   read).
4. Snapshot the current config surface: `pacman -Qqet`, `systemctl
   list-unit-files`, `~/.config` tree, Hyprland/waybar/kitty configs.

Exit criteria: NVMe under 70 %, `sda` content either proven redundant or
copied to `sdb2`, all three disks mounted intentionally.

### Phase 1 — build the config green, on the t490s

1. Write the new modules (§6.1–6.8).
2. `nix build` the whole `desktop` closure **on the t490s** (it is the builder +
   cache for the fleet) — full evaluation plus a real build, so nothing is
   discovered on install day.
3. Optional: boot it in a QEMU/`vmtest`-style VM to check the graphical session,
   fonts, bar and keybinds before any disk is touched.

Exit criteria: `desktop` closure builds, `vmtest` boots to a working Hyprland.

### Phase 2 — install NixOS next to Arch (rehearsal, reversible)

1. Free `sda`: only after Phase 0 proves its content is redundant (or copies
   it to the HDD).
2. Partition `sda` with disko (`hardware/desktop-disko.nix`), install with its
   own ESP, keep the NVMe ESP + Arch untouched.
3. Firmware boot menu gets a second entry — Arch stays selectable.
4. **Playtest for real:** Steam library path, Proton, gamescope, controller,
   audio latency in game, 165 Hz, suspend, Discord voice.

Exit criteria: a week of real gaming on NixOS with no reason to boot Arch.

### Phase 3 — cutover

1. Final data sync: `~` → SSD `/data`, games → `@games`, caches left behind.
2. Reinstall NixOS on the NVMe with the final layout (§6.8), point disko at the
   NVMe, keep `sda` as `/data`.
3. Boot the new system, verify, then **wipe `sda`'s old Arch-era partition
   table** and format it as `/data` (or keep it as an emergency Arch for another
   month — it costs nothing).
4. Only after a clean week: remove the Arch ESP entry.

Rollback at every step: the previous disk is still there, still bootable.

### Phase 4 — finish

- btrbk/restic schedule to the HDD, restore test.
- Secrets: Vaultwarden/Bitwarden on the desktop, SSH keys, GPG.
- Optional: Hermes client so the desktop can talk to the agent like the t14 does.

---

## 8. Decisions needed (defaults are what I will do if he says nothing)

1. **Music production stack** — keep, shrink, or drop?
   *Default: shrink* to PipeWire + JACK + a named shortlist (guitarix, carla,
   sfizz, drumgizmo, LSP, Calf) and drop the rest of the LV2 zoo.
2. **Ollama on the desktop** — 16 GB RAM, CPU-only inference at a few tokens/s,
   while the t490s and the VPS exist.
   *Default: drop* (keep the decision open to add `services.ollama` later).
3. **Android toolchain** — needed for school or is it one project from 2024?
   *Default: install* (`android-studio` + androidenv), it is a few GB the SSD
   can carry, but it will not go on the NVMe.
4. **Non-Steam game data** (~160 GB of repacks/Epic copies/DOOM) — carry, or
   let it die with the old disk?
   *Default: carry the ones with save data; the rest stays on the HDD unbacked.*
5. **Printing** — dead printer, drop CUPS?
   *Default: drop.*
6. **Blender/ROCm** — install HIP so GPU rendering works (~4 GB), or CPU?
   *Default: install*, since he named Blender explicitly as the reason the box
   is not purely a console.
7. **`sda` old home** — is anything on it unique that he knows of?
   (I will produce the report first; this is a "tell me if you remember
   something" question, not a blocker.)
8. **Stage-2 rehearsal disk** — the plan uses `sda` for the trial install, which
   means it must be free. Alternative: trial install on the HDD's unused space.

---

## 9. Unknowns I could not determine from the machine

- Which games he actually still plays (the Steam manifest lists ~45 titles,
  ~510 GB; there is no playtime data reachable without reading personal config).
- Whether the `jc141` / CODEX trees carry saves he cares about.
- Whether the DeskJet is genuinely gone.
- Whether he wants the desktop to hibernate (decides swapfile or not).
- Whether the 165 Hz panel does FreeSync (decides VRR settings).

---

## 10. Verification checklist (per phase)

**Phase 0** — `df -h` before/after, `pacman -Qtdq` empty, all three disks in
`lsblk` with intended mounts, `sda` report written.

**Phase 1** — `nix build .#nixosConfigurations.desktop.config.system.build.toplevel`
exits 0 on the t490s; kernel eval prints a `cachyos` version; gaming stack eval
lists steam/mangohud/goverlay/proton-ge.

**Phase 2** — `bootctl list` shows two entries; `hyprctl monitors` shows 165 Hz;
a Proton title runs; controller pairs; `pactl info` shows PipeWire with the
right sink; `nixos-rebuild switch` rollback works.

**Phase 3** — `df -h` shows the intended split; `btrfs subvolume list` matches
§6.8; Steam finds the library on `@games`; `btrbk list` shows a snapshot;
restore one file from it.

**Phase 4** — restic check passes, secrets present, one full week without
booting Arch.
