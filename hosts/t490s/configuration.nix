# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, inputs, pkgs, ... }:

{
  imports =
    [
      inputs.mangowc.nixosModules.mango
    ];

  nixpkgs.overlays = [
        (self: super: {
            lmms = super.lmms.overrideAttrs {
                version = "1.3.0-alpha.1";
                src = pkgs.fetchFromGitHub {
                    owner = "LMMS";
                    repo = "lmms";
                    rev = "bda042e1eb59e4c7508faa072051c50c2e12894d";
                    sha256 = "sha256-EGJcTzPUkIqURHKjX6dTRkeRTqwHM8eG74lYVILgSAs";
                    fetchSubmodules = true;
                };
                patches = [];
            };
        })
    ];

  documentation.man.generateCaches = false;
  
  hardware.opentabletdriver.enable = true;
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    stdenv.cc.cc
    zlib
    fuse3
    icu
    zlib
    nss
    openssl
    curl
    expat
    # Common Android dependencies?
    glibc
    glib
    ncurses5
  ];

  systemd.oomd = {
    enable = true;
    enableUserSlices = true; # Act on user sessions
  };

  stylix = {
    enable = true;
    base16Scheme = "${pkgs.base16-schemes}/share/themes/onedark-dark.yaml";

    # iconTheme = {
    #   enable = true;
    #   package = pkgs.tela-icon-theme;
    # };

    targets = {
      plymouth.enable = false;
    };
  };

  # boot.loader.grub = {
  #   enable = true;
  #   theme = "${pkgs.catppuccin-grub}";
  # };


  # Bootloader.
  services.fwupd.enable = true;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.plymouth = {
    enable = true;
    theme = "connect";
    themePackages = with pkgs; [
      (adi1090x-plymouth-themes.override {
        selected_themes = [ "connect" ];
      })
    ];
  };
  boot.loader.timeout = 0;
  boot.kernelParams = [
    "quiet"
    "splash"
    "boot.shell_on_fail"
  ];

  services.udev.extraRules = ''
  ACTION=="add", ATTRS{idVendor}=="2dc8", ATTRS{idProduct}=="301c", MODE="0666", \
  RUN+="/sbin/modprobe xpad", \
  RUN+="/bin/sh -c 'echo 2dc8 301c > /sys/bus/usb/drivers/xpad/new_id'"
  KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{serial}=="*vial:f64c2b3c*", MODE="0660", GROUP="users", TAG+="uaccess", TAG+="udev-acl"
  '';

  nix.settings.substituters = [
  	"https://cache.nixos.org/"
  	"https://cache.garnix.io "
  	"https://nix-logseq-git-flake.cachix.org"
  	"https://noctalia.cachix.org"
  ];
  nix.settings.trusted-public-keys = [
  	"cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
  	"cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
    "nix-logseq-git-flake.cachix.org-1:DSBNW07PSRyCvS926tpIWahb53OIydwwZhsP6LhJNZo="
    "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4="
  ];

  nix.extraOptions = "eval-cores = 0\n";

  networking.hostName = "t490s"; # Define your hostname.
  services.tailscale.enable = true;
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Enable networking
  networking.networkmanager.enable = true;
  services.resolved.enable = true;

  # Set your time zone.
  time.timeZone = "Europe/Prague";

  # Select internationalisation properties.
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

  # Enable the X11 windowing system.
  # services.xserver.enable = true;

  programs.kdeconnect.enable = true;
  
  # programs.nix-ld.enable = true;

  # Enable the GNOME Desktop Environment.
  # services.xserver.displayManager.gdm.enable = true;
  # services.xserver.desktopManager.gnome.enable = true;

  services.desktopManager.cosmic.enable = true;
  # services.displayManager.cosmic-greeter.enable = true;

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "cz";
    variant = "";
  };

  # Configure console keymap
  console.keyMap = "cz-lat2";

  # Enable CUPS to print documents.
  services.printing.enable = true;

  # Enable opengl
  hardware.graphics.enable = true;

  # Enable sound with pipewire.
  hardware.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # If you want to use JACK applications, uncomment this
    #jack.enable = true;

    # use the example session manager (no others are packaged yet so this is enabled by default,
    # no need to redefine it in your config for now)
    #media-session.enable = true;
  };

  # Enable touchpad support (enabled default in most desktopManager).
  # services.xserver.libinput.enable = true;
  powerManagement.powertop.enable = true;

  services.power-profiles-daemon.enable = false;

  programs.steam.enable = true;
  programs.gamemode.enable = true;
  programs.gamescope.enable = true;

  programs.fish.enable = true;
  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.pebor = {
    isNormalUser = true;
    shell = pkgs.fish;
    description = "pebor";
    extraGroups = [ "networkmanager" "wheel" "adbusers" "kvm" ];
  };

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # programs.waybar.enable = true;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # environment.sessionVariables.NIXOS_OZONE_WL = "1";
  environment.sessionVariables = {
    NIXOS_OZONE_WL = "1";
    TERMINAL = "foot";
  };

  services.auto-cpufreq.enable = true;

  programs.hyprland.enable = true;
  programs.hyprlock.enable = true;
  services.hypridle.enable = true;

  programs.niri.enable = true;
  programs.xwayland.enable = true;

  programs.mango.enable = true;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    auto-cpufreq

    niri
    # inputs.shko.packages.${system}.default

    gamescope
    gamemode

    android-tools
    android-studio

    inputs.logseq-nightly.packages.${pkgs.system}.logseq
    inputs.logseq-nightly.packages.${pkgs.system}.logseq-cli

    inputs.noctalia.packages.${pkgs.stdenv.hostPlatform.system}.default

    lmms
    base16-schemes
  ];

  fonts.enableDefaultPackages = true;
  fonts.fontDir.enable = true;
  fonts.fontconfig.enable = true;

  fonts.packages = with pkgs; [
    material-design-icons
    noto-fonts
    cascadia-code
    # maple-mono
    nerd-fonts.jetbrains-mono
    nerd-fonts.mononoki
    nerd-fonts.fira-code
    nerd-fonts.fira-mono
    noto-fonts-cjk-sans
    corefonts
    vista-fonts
    google-fonts
    roboto-mono
    googlesans-code
  ];

  hardware.bluetooth.enable = true;

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  # services.openssh.enable = true;

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "24.11"; # Did you read the comment?

}
