# Expose the pinned Hermes Agent package as a flake output so it can be
# built and inspected on its own: nix build .#hermes-agent
{ inputs, ... }:
{
  perSystem = { system, ... }: {
    packages.hermes-agent =
      inputs.hermesAgentSrc.packages.${system}.default.override {
        version = "0.23.1";
      };
  };
}
