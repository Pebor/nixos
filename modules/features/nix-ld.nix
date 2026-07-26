# nix-ld for running unpatched dynamic binaries (t490s).
{
  flake.modules.nixos.nix-ld = { pkgs, ... }: {
    programs.nix-ld.enable = true;
    programs.nix-ld.libraries = with pkgs; [
      stdenv.cc.cc
      zlib
      fuse3
      icu
      nss
      openssl
      curl
      expat
      # Common Android dependencies?
      glibc
      glib
      ncurses5
    ];
  };
}
