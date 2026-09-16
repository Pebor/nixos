{
  description = "pebor's NixOS + Home Manager configurations (dendritic, flake-parts)";

  # Binary caches active even before the system config applies (e.g. during
  # `nixos-install` from the ISO). Mirror of modules/base/nix.nix — keep in sync.
  nixConfig = {
    extra-substituters = [
      "https://cache.garnix.io"
      "https://nix-logseq-git-flake.cachix.org"
      "https://noctalia.cachix.org"
      "https://helix.cachix.org"
    ];
    extra-trusted-public-keys = [
      "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
      "nix-logseq-git-flake.cachix.org-1:DSBNW07PSRyCvS926tpIWahb53OIydwwZhsP6LhJNZo="
      "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4="
      "helix.cachix.org-1:ejp9KQpR1FBI2onstMQ34yogDm4OgU2ru6lIwPvuCVs="
    ];
  };

  inputs = {
    # Two nixpkgs inputs with independent update cadence:
    #   nixpkgs    -> system (nixos-rebuild), updated every few weeks
    #   nixpkgs-hm -> standalone Home Manager, updated daily
    # Update selectively:
    #   nix flake lock --update-input nixpkgs
    #   nix flake lock --update-input nixpkgs-hm
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs-hm.url = "github:nixos/nixpkgs/nixos-unstable";

    flake-parts.url = "github:hercules-ci/flake-parts";
    import-tree.url = "github:vic/import-tree";

    # --- Home-Manager-side inputs (follow nixpkgs-hm) ---
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs-hm";
    };
    # NOTE: inputs with their own binary caches (helix, logseq-nightly,
    # noctalia) deliberately do NOT follow our nixpkgs — overriding their
    # nixpkgs changes the derivation and makes their cache miss, forcing a
    # local source build. They pull their own (binary-cached) nixpkgs pin.
    helix.url = "github:helix-editor/helix";
    helium = {
      url = "github:schembriaiden/helium-browser-nix-flake";
      inputs.nixpkgs.follows = "nixpkgs-hm";
    };
    logseq-nightly.url = "github:Bad3r/nix-logseq-git-flake";
    zen-browser.url = "github:0xc000022070/zen-browser-flake";
    rose-pine-hyprcursor.url = "github:ndom91/rose-pine-hyprcursor";
    # Kept intentionally: Affinity suite. Usage stays commented out in
    # modules/home/packages-apps.nix until needed.
    affinity-nix.url = "github:mrshmllow/affinity-nix";

    # --- NixOS-system-side inputs (follow nixpkgs) ---
    stylix = {
      url = "github:nix-community/stylix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/*";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    mangowc = {
      url = "github:mangowm/mango";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    noctalia.url = "github:noctalia-dev/noctalia-shell";
    # Kept intentionally for a possible bleeding-edge niri. NOT used by default:
    # the niri flake has no binary cache, so using it means a long local Rust
    # build on every update. modules/features/niri.nix uses the (cached)
    # nixpkgs package instead; switch `programs.niri.package` there if wanted.
    niri = {
      url = "github:YaLTeR/niri";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];
      imports = [
        inputs.flake-parts.flakeModules.modules
        (inputs.import-tree ./modules)
      ];
    };
}
