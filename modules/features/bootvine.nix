# bootvine — live tree of systemd jobs on the boot console, from its flake.
# Replaces the plymouth splash (modules/features/plymouth.nix is kept for
# rollback): bootvine owns the boot console instead of a splash covering it.
{ inputs, ... }:
{
  flake.modules.nixos.bootvine = {
    imports = [ inputs.bootvine.nixosModules.default ];

    services.bootvine.enable = true;

    # Carried over from the plymouth aspect: no boot-menu wait, and a shell
    # when stage 2 fails instead of a black screen.
    boot.loader.timeout = 0;
    boot.kernelParams = [ "boot.shell_on_fail" ];
  };
}
