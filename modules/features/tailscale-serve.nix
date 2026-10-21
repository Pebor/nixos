# Declarative tailnet HTTPS exposure (`tailscale serve`) — the source of
# truth for every tailnet-only web endpoint on this host. Do NOT hand-edit
# serve config with the tailscale CLI; change it here and rebuild.
#
# Each command is an idempotent replace of the "/" handler for its port.
# tailscaled additionally persists serve config tailnet-side, so this unit
# is the deterministic re-apply on top of that (boot, reinstall, re-add).
{
  flake.modules.nixos.tailscale-serve = { pkgs, ... }: {
    systemd.services.tailscale-serve = {
      description = "Apply tailscale serve endpoints (tailnet HTTPS)";
      after = [ "tailscaled.service" ];
      wants = [ "tailscaled.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.tailscale ];
      # Warn-only on purpose: a rebuild must never fail over one endpoint
      # (house rule). Check `systemctl status tailscale-serve` after boot.
      script = ''
        tailscale serve --bg --https=8443 /var/lib/hermes/personal/demos \
          || echo "WARN: tailscale-serve: :8443 (demos) not applied"
        tailscale serve --bg --https=8444 http://127.0.0.1:9119 \
          || echo "WARN: tailscale-serve: :8444 (dashboard) not applied"
        tailscale serve --bg --https=8445 http://127.0.0.1:8085 \
          || echo "WARN: tailscale-serve: :8445 (vaultwarden) not applied"
      '';
    };
  };
}
