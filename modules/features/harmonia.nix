# Harmonia binary cache (t490s-server): serves the local nix store to other
# machines over tailscale. Anything in the server's store is served — no push
# step needed, which is what makes cache-warm (see cache-warm.nix) work.
#
# Post-install bootstrap (one time, on the server):
#   sudo install -d /var/lib/harmonia
#   sudo nix-store --generate-binary-cache-key t490s-cache-1 \
#     /var/lib/harmonia/cache-key.pem /var/lib/harmonia/cache-key.pub
#   sudo systemctl restart harmonia.service
# Then put the .pub contents into build-client.nix on the clients.
{
  flake.modules.nixos.harmonia = {
    services.harmonia.cache = {
      enable = true;
      signKeyPaths = [ "/var/lib/harmonia/cache-key.pem" ];

      # Bind to the tailnet address, NOT the upstream default [::]:5000.
      # The module derives the socket's ListenStream from this value, so the
      # bind itself is the access control. With [::] the cache was on every
      # interface and the firewall did not stop it (2026-10-25:
      # http://10.50.104.168:5000/nix-cache-info answered 200 off-tailnet).
      settings.bind = "100.103.136.50:5000";
      settings.priority = 40;
    };

    # The socket can only bind once tailscale0 carries its address, so tie it
    # to the readiness gate (tailscaled.service alone starts too early) and let
    # systemd retry the bind if it loses that race anyway.
    systemd.sockets.harmonia = {
      after = [ "tailscale-wait-address.service" ];
      wants = [ "tailscale-wait-address.service" ];
      socketConfig.Restart = "on-failure";
      socketConfig.RestartSec = 5;
    };

    # Cache and SSH are reachable over tailscale only — nothing on the LAN.
    networking.firewall.trustedInterfaces = [ "tailscale0" ];
  };
}
