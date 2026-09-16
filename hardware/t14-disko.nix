# t14 — disk layout (disko). Plain attrset: works both as disko CLI input
# at install time and as a NixOS module imported by modules/hosts/t14.nix,
# so the installed system carries its own layout (fileSystems stay out of
# hardware/t14.nix — generate that with `nixos-generate-config --no-filesystems`).
#
# Install-time usage from the NixOS ISO (WIPES THE DISK):
#   sudo nix run github:nix-community/disko/latest -- --mode disko ~/nixos/hardware/t14-disko.nix
#
# 512 GB SSD: 1G ESP + 16G swap (== RAM, hibernation-ready) + btrfs rest.
{
  disko.devices.disk.main = {
    # Verify with `lsblk` on the machine before running disko!
    device = "/dev/nvme0n1";
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "fmask=0022" "dmask=0022" ];
          };
        };
        swap = {
          size = "16G";
          content = {
            type = "swap";
            discardPolicy = "both";
            resumeDevice = true; # sets boot.resumeDevice for hibernation
          };
        };
        root = {
          size = "100%";
          content = {
            type = "btrfs";
            extraArgs = [ "-f" ];
            subvolumes = {
              "@root" = {
                mountpoint = "/";
                mountOptions = [ "compress=zstd" ];
              };
              "@home" = {
                mountpoint = "/home";
                mountOptions = [ "compress=zstd" ];
              };
              "@nix" = {
                mountpoint = "/nix";
                mountOptions = [ "compress=zstd" "noatime" ];
              };
            };
          };
        };
      };
    };
  };
}
