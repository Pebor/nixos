# bootvine — live tree of systemd jobs on the boot console, from its flake.
# It paints over the console, so it only makes sense where someone watches the
# boot; on hosts with plymouth/`quiet splash` the two fight over the VT, so
# either drop plymouth there or don't import this aspect.
{ inputs, ... }:
{
  flake.modules.nixos.bootvine = {
    imports = [ inputs.bootvine.nixosModules.default ];

    services.bootvine.enable = true;
  };
}
