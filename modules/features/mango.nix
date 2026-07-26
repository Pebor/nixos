# mango (mangowc) Wayland compositor, from its flake.
# No upstream binary cache — builds from source (status quo).
{ inputs, ... }:
{
  flake.modules.nixos.mango = {
    imports = [ inputs.mangowc.nixosModules.mango ];
    programs.mango.enable = true;
  };
}
