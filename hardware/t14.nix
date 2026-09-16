# Placeholder — replaced on the t14 during install by:
#   sudo nixos-generate-config --no-filesystems --root /mnt
#   cp /mnt/etc/nixos/hardware-configuration.nix ~/nixos/hardware/t14.nix
# (--no-filesystems because disko owns fileSystems via hardware/t14-disko.nix)
{ lib, ... }: {
  # So the flake evaluates before the real file exists; the generated file
  # sets this too (mkDefault), same value.
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
