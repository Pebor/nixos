# Settings shared by every NixOS host: bootloader, locale, networking,
# and a minimal set of system tools (kept for recovery situations).
{
  flake.modules.nixos.system = { pkgs, ... }: {
    # Bootloader.
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

    # Networking.
    networking.networkmanager.enable = true;

    # Time zone and internationalisation.
    time.timeZone = "Europe/Prague";
    i18n.defaultLocale = "en_US.UTF-8";
    i18n.extraLocaleSettings = {
      LC_ADDRESS = "cs_CZ.UTF-8";
      LC_IDENTIFICATION = "cs_CZ.UTF-8";
      LC_MEASUREMENT = "cs_CZ.UTF-8";
      LC_MONETARY = "cs_CZ.UTF-8";
      LC_NAME = "cs_CZ.UTF-8";
      LC_NUMERIC = "cs_CZ.UTF-8";
      LC_PAPER = "cs_CZ.UTF-8";
      LC_TELEPHONE = "cs_CZ.UTF-8";
      LC_TIME = "cs_CZ.UTF-8";
    };

    # Always-available system tools (editor + nix helper).
    environment.systemPackages = with pkgs; [
      neovim
      nh
    ];
  };
}
