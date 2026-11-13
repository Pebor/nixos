# Expose the pinned Hermes Agent package as a flake output so it can be
# built and inspected on its own: nix build .#hermes-agent
#
# The pin itself (which version, which patches) lives in
# lib/hermes-pin.nix, because the service units and the CLI wrapper
# must run the very same build as this output.
{ inputs, ... }:
{
  perSystem = { system, pkgs, ... }: {
    packages.hermes-agent = import ../../lib/hermes-pin.nix { inherit inputs pkgs; };
  };
}
