# Tailscale VPN.
#
# `after = tailscaled.service` is NOT enough for anything that binds the
# tailnet address: tailscaled is up long before tailscale0 carries its 100.x
# address. 2026-10-27 showed both failure modes — harmonia's socket died with
# "Failed to receive listening socket (I/O error)" and edge-dnsmasq published
# 100.103.136.50:53, lost the bind race and came up with NO network at all
# (only loopback), which took every *.pebor.me name down with it.
# This oneshot is the single readiness point: depend on it instead of on
# tailscaled.service. Bounded, and only Wanted (never Required) by consumers,
# so a tailnet that never comes up cannot block boot.
{
  flake.modules.nixos.tailscale = { pkgs, ... }: {
    services.tailscale.enable = true;

    systemd.services.tailscale-wait-address = {
      description = "Wait for the tailscale0 IPv4 address";
      after = [ "tailscaled.service" ];
      wants = [ "tailscaled.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.iproute2 pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "70s";
      };
      script = ''
        for _ in $(seq 1 60); do
          if ip -4 addr show dev tailscale0 2>/dev/null | grep -q "inet 100\."; then
            echo "tailscale0 is up with $(ip -4 -o addr show dev tailscale0 | awk '{print $4}')"
            exit 0
          fi
          sleep 1
        done
        echo "tailscale0 did not get an IPv4 address within 60s" >&2
        exit 1
      '';
    };
  };
}
