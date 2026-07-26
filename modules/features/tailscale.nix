# Tailscale VPN.
{
  flake.modules.nixos.tailscale = {
    services.tailscale.enable = true;
  };
}
