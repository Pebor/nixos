# Service-vault materialization: pull `env/<KEY>` items from the bw service
# vault into ${stateDir}/.env (the file hermes reads — see the secrets-layer
# design). The vault is the source of truth; .env is the derived artifact.
# Per-key replace only — never rewrites or reorders unrelated lines.
# Warn-only everywhere: a missing secret must never fail anything (pitfall 13).
{
  flake.modules.nixos.hermes-secrets-sync = { pkgs, ... }: {
    systemd.services.hermes-secrets-sync = {
      description = "Materialize service-vault secrets (bw) into hermes .env";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = [ pkgs.bitwarden-cli pkgs.coreutils pkgs.gnused ];
      serviceConfig = {
        Type = "oneshot";
        User = "server";
        Group = "users";
      };
      script = ''
        ENV=/var/lib/hermes/.env
        log() { echo "secrets-sync: $*"; }
        PW=$(sed -n 's/^BW_SERVICE_MASTER_PASSWORD=//p' "$ENV" | head -1)
        if [ -z "$PW" ]; then log "WARN: BW_SERVICE_MASTER_PASSWORD missing in .env"; exit 0; fi
        export BW_TRY="$PW"
        BW_SESSION=$(bw unlock --raw --passwordenv BW_TRY 2>/dev/null | tail -1)
        if [ -z "$BW_SESSION" ]; then log "WARN: bw unlock failed (vault unreachable?)"; exit 0; fi
        export BW_SESSION
        bw sync >/dev/null 2>&1 || log "WARN: bw sync failed (using cached vault)"
        NAMES=$(bw list items 2>/dev/null | tr ',' '\n' | grep '"name":"env/' | sed 's/^.*"name":"env\///; s/".*$//' | sort -u)
        UPDATED=0; UNCHANGED=0
        for k in $NAMES; do
          case "$k" in *[!A-Za-z0-9_]*) log "skipping odd item name"; continue ;; esac
          v=$(bw get password "env/$k" --raw 2>/dev/null | tr -d '\n')
          [ -n "$v" ] || continue
          cur=$(sed -n "s/^$k=//p" "$ENV" | head -1)
          if [ "$cur" = "$v" ]; then UNCHANGED=$((UNCHANGED+1)); continue; fi
          tmp=$(mktemp); found=0
          while IFS= read -r line; do
            case "$line" in
              "$k="*) if [ "$found" = 0 ]; then printf '%s=%s\n' "$k" "$v"; found=1; fi ;;
              *) printf '%s\n' "$line" ;;
            esac
          done < "$ENV" > "$tmp"
          [ "$found" = 0 ] && printf '%s=%s\n' "$k" "$v" >> "$tmp"
          cat "$tmp" > "$ENV"
          rm -f "$tmp"
          UPDATED=$((UPDATED+1))
        done
        log "done: $UPDATED updated, $UNCHANGED unchanged"
        exit 0
      '';
    };

    systemd.timers.hermes-secrets-sync = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3min";
        OnUnitActiveSec = "6h";
      };
    };
  };
}
