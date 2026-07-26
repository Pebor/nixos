# KDE Plasma 6 + SDDM display stack (t420).
{
  flake.modules.nixos.plasma = {
    services.xserver.enable = true;
    services.displayManager.sddm.enable = true;
    services.desktopManager.plasma6.enable = true;
  };
}
