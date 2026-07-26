# Laptop power management (t490s).
{
  flake.modules.nixos.laptop = { pkgs, ... }: {
    services.auto-cpufreq.enable = true;
    environment.systemPackages = [ pkgs.auto-cpufreq ];

    powerManagement.powertop.enable = true;
    services.power-profiles-daemon.enable = false;
  };
}
