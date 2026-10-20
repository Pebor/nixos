# Compressed RAM swap (zstd) as the fast swap tier in front of any disk
# swap. Covers burst memory pressure (parallel compiles, Android Studio +
# emulator, Docker) without NVMe swap stalls or SSD wear. NixOS defaults:
# zstd, device sized to 50% of RAM, priority above disk swap.
# Cannot back hibernation - that needs disk-backed swap.
{
  flake.modules.nixos.zram = {
    zramSwap.enable = true;
  };
}
