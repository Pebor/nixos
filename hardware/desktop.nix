# FIXME: placeholder — replace with the output of `nixos-generate-config`
# (hardware-configuration.nix) on the actual desktop PC before switching.
# Until then this host builds but is NOT bootable.
{ lib, ... }:
{
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # FIXME: dummy root filesystem so the configuration evaluates — the real
  # one comes from nixos-generate-config. DO NOT install/switch with this.
  fileSystems."/" = {
    device = lib.mkDefault "/dev/disk/by-label/nixos";
    fsType = lib.mkDefault "ext4";
  };
}
