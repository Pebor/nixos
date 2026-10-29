# Service-vault materialization: pull `env/<KEY>` items from the bw service
# vault into ${stateDir}/.env (the file hermes reads).
#
# KEY OWNERSHIP (one owner per key, no fighting writers):
#   - a key declared in secrets.env      -> owned by secrets.env; SKIPPED here
#                                          (hermes-env-sync writes it into .env)
#   - a key only in the vault            -> owned by the vault, replaced here
# OPENCODE_GO_API_KEY lives in the vault only, so a rate-limited key is
# swapped from the Bitwarden UI — trigger at once with:
#   sudo systemctl start hermes-secrets-sync
# Per-key replace only — never rewrites or reorders unrelated lines.
# Warn-only everywhere: a missing secret must never fail anything (pitfall 13).
{
  flake.modules.nixos.hermes-secrets-sync = { pkgs, ... }: {
    systemd.services.hermes-secrets-sync = {
      description = "Materialize service-vault secrets (bw) into hermes .env";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = [ pkgs.bitwarden-cli pkgs.coreutils pkgs.gnused pkgs.jq ];
      serviceConfig = {
        Type = "oneshot";
        User = "server";
        Group = "users";
      };
      script = ''
        ENV=/var/lib/hermes/.env
        MASTER=/var/lib/hermes/secrets.env
        log() { echo "secrets-sync: $*"; }
        PW=$(sed -n 's/^BW_SERVICE_MASTER_PASSWORD=//p' "$ENV" | head -1)
        if [ -z "$PW" ]; then log "WARN: BW_SERVICE_MASTER_PASSWORD missing in .env"; exit 0; fi
        export BW_TRY="$PW"
        BW_SESSION=$(bw unlock --raw --passwordenv BW_TRY 2>/dev/null | tail -1)
        if [ -z "$BW_SESSION" ]; then log "WARN: bw unlock failed (vault unreachable?)"; exit 0; fi
        export BW_SESSION
        bw sync >/dev/null 2>&1 || log "WARN: bw sync failed (using cached vault)"
        # Snapshot once, resolve every item by EXACT name to its id: `bw get`
        # is fuzzy (a second item sharing a word like "opencode" makes the
        # lookup ambiguous and silently yields nothing), id lookups are not.
        ITEMS=$(bw list items 2>/dev/null)
        NAMES=$(printf '%s' "$ITEMS" | jq -r '.[] | select(.name|startswith("env/")) | .name' 2>/dev/null | sed 's|^env/||' | sort -u)
        [ -n "$NAMES" ] || log "WARN: no env/* items visible (vault empty or locked?)"
        UPDATED=0; UNCHANGED=0
        for k in $NAMES; do
          case "$k" in *[!A-Za-z0-9_]*) log "skipping odd item name"; continue ;; esac
          # secrets.env wins: never overwrite a key the user declares there.
          if grep -q "^$k=." "$MASTER" 2>/dev/null; then
            log "skip $k (owned by secrets.env)"
            continue
          fi
          id=$(printf '%s' "$ITEMS" | jq -r --arg n "env/$k" '.[] | select(.name==$n) | .id' 2>/dev/null | head -1)
          [ -n "$id" ] || { log "skip $k (no exact item named env/$k)"; continue; }
          v=$(bw get password "$id" --raw 2>/dev/null | tr -d '\n')
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
