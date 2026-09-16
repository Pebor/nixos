# niri — scrollable-tiling Wayland compositor.
#
# Uses the nixpkgs package (binary-cached). The `niri` flake input is kept
# for bleeding-edge builds but intentionally unused: it has no binary cache,
# so `programs.niri.package = inputs.niri.packages.${pkgs.stdenv.hostPlatform.system}.default`
# would mean a long local Rust build on every nixpkgs bump.
{
  flake.modules.nixos.niri = { pkgs, ... }: {
    programs.niri.enable = true;
    # programs.niri.enable already adds the package to systemPackages.
  };
}
