{ pkgs, ...}: {
  home.packages = with pkgs; [
    # teams-for-linux

    # rnote
    # xournalpp

    # logisim-evolution
    # jetbrains.datagrip
    # postgresql

    # anki-bin

    # PPA
    haskellPackages.stack
    haskell-language-server
    haskellPackages.ghc

    # TJV
    # jetbrains.idea-ultimate
    # maven

    # IDO
    # google-chrome
    # chromedriver
    openvpn
    update-systemd-resolved
    networkmanager-openvpn
    # docker
    # podman
  ];
}
