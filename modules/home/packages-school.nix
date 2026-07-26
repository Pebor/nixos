# School-related programs (superset of the old per-host copies).
{
  flake.modules.homeManager.packages-school = { pkgs, ... }: {
    home.packages = with pkgs; [
      rnote
      xournalpp

      postgresql

      anki-bin

      # PPA
      haskellPackages.stack
      haskell-language-server
      haskellPackages.ghc
      swi-prolog

      # TJV
      jetbrains.idea
      maven
      jdt-language-server

      # IDO
      docker
      podman
    ];
  };
}
