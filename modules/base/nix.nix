# Nix daemon settings, binary caches and nixpkgs config shared by all hosts.
{
  flake.modules.nixos.nix-settings =
    {
      config,
      lib,
      ...
    }:
    {
      nix.settings = {
        experimental-features = [ "nix-command" "flakes" ];
        auto-optimise-store = true;
        substituters = [
          "https://cache.nixos.org/"
          "https://nix-logseq-git-flake.cachix.org"
          "https://noctalia.cachix.org"
          "https://helix.cachix.org"
        ];
        trusted-public-keys = [
          "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
          "nix-logseq-git-flake.cachix.org-1:DSBNW07PSRyCvS926tpIWahb53OIydwwZhsP6LhJNZo="
          "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4="
          "helix.cachix.org-1:ejp9KQpR1FBI2onstMQ34yogDm4OgU2ru6lIwPvuCVs="
        ];
      };

      # All-core evaluation. `eval-cores` is a Determinate Nix setting only:
      # upstream nix (t420/t420-server do not import the determinate module)
      # rejects it as an unknown setting, and nixpkgs now validates the
      # generated nix.conf with the host's own nix binary — so on those hosts
      # the whole system build died with "error: unknown setting 'eval-cores'".
      # Gate the setting on the package that actually supports it.
      nix.extraOptions = lib.optionalString
        (lib.hasInfix "determinate" config.nix.package.name)
        "eval-cores = 0\n";

      nixpkgs.config.allowUnfree = true;

      # Avoid the expensive man-db cache build on every system change.
      documentation.man.cache.enable = false;
    };

  flake.modules.homeManager.nix-settings = {
    nixpkgs.config.allowUnfree = true;
  };
}
