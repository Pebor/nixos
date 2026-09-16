# Desktop plumbing shared by graphical hosts: audio, graphics, printing,
# bluetooth, fonts, kdeconnect and Wayland-friendly session variables.
{
  flake.modules.nixos.desktop = { pkgs, ... }: {
    # Sound via pipewire.
    services.pulseaudio.enable = false;
    security.rtkit.enable = true;
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
    };

    hardware.graphics.enable = true;
    hardware.bluetooth.enable = true;

    services.printing.enable = true;
    programs.kdeconnect.enable = true;

    environment.sessionVariables = {
      NIXOS_OZONE_WL = "1";
      TERMINAL = "foot";
    };

    fonts.enableDefaultPackages = true;
    fonts.fontDir.enable = true;
    fonts.fontconfig.enable = true;
    # corefonts/vista-fonts (flaky SourceForge fetch) and google-fonts
    # (~1.5 GB) intentionally omitted — slow down fresh installs.
    fonts.packages = with pkgs; [
      material-design-icons
      noto-fonts
      cascadia-code
      nerd-fonts.jetbrains-mono
      nerd-fonts.mononoki
      nerd-fonts.fira-code
      nerd-fonts.fira-mono
      noto-fonts-cjk-sans
      roboto-mono
      googlesans-code
    ];
  };
}
