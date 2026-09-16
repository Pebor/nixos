# Nix daemon settings, binary caches and nixpkgs config shared by all hosts.
{
  flake.modules.nixos.nix-settings = {
    nix.settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;
      substituters = [
        "https://cache.nixos.org/"
        "https://cache.garnix.io"
        "https://nix-logseq-git-flake.cachix.org"
        "https://noctalia.cachix.org"
        "https://helix.cachix.org"
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
        "nix-logseq-git-flake.cachix.org-1:DSBNW07PSRyCvS926tpIWahb53OIydwwZhsP6LhJNZo="
        "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4="
        "helix.cachix.org-1:ejp9KQpR1FBI2onstMQ34yogDm4OgU2ru6lIwPvuCVs="
      ];
    };

    # Use all cores for evaluation (was t490s-only).
    nix.extraOptions = "eval-cores = 0\n";

    nixpkgs.config.allowUnfree = true;

    # Avoid the expensive man-db cache build on every system change.
    documentation.man.cache.enable = false;
  };

  flake.modules.homeManager.nix-settings = {
    nixpkgs.config.allowUnfree = true;
  };
}
