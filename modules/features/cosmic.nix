# COSMIC desktop environment.
{
  flake.modules.nixos.cosmic = {
    services.desktopManager.cosmic.enable = true;
    # services.displayManager.cosmic-greeter.enable = true;  # greetd is used instead
  };
}
