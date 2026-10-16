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
      # bind defaults to [::]:5000; firewall below restricts it to tailscale.
      settings.priority = 40;
    };

    # Cache and SSH are reachable over tailscale only — nothing on the LAN.
    networking.firewall.trustedInterfaces = [ "tailscale0" ];
  };
}
