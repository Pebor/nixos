# Declares the `flake.homeConfigurations` output option.
# flake-parts already knows `flake.nixosConfigurations`, but not the
# Home Manager equivalent — declaring it here lets every host file define
# its own entry and have them merged automatically.
{ lib, ... }:
{
  options.flake.homeConfigurations = lib.mkOption {
    type = lib.types.lazyAttrsOf lib.types.attrs;
    default = { };
  };
}
