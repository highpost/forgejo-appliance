#!/bin/zsh

setopt ERR_EXIT
setopt PIPE_FAIL

source "./config.env"
source "./utils.sh"

# dump the domain validation certificates and Forgejo data to the macOS host
backup_appliance_state() {
    if ! orb list | grep "$FORGEJO_VM" > /dev/null; then
        log_info "VM instance $FORGEJO_VM is already stopped or missing. Skipping cert backup."
        return
    fi

    # halt the reverse proxy to safely flush the Tailscale database to disk
    orb exec -m "$FORGEJO_VM" sudo systemctl stop tsbridge
    local ts_state_b64
    ts_state_b64=$(orb exec -m "$FORGEJO_VM" sudo tar -cf - -C /var/lib/tsbridge . | base64 -b 0)

    if [ -n "$ts_state_b64" ]; then
        security add-generic-password -a "$USER" -s "$TS_CERT_CACHE" -w "$ts_state_b64" -U
    else
        log_info "no certificate state found inside the VM to back up."
    fi

    # halt the forgejo service to ensure database consistency
    orb exec -m "$FORGEJO_VM" sudo systemctl stop forgejo
    # remove any leftover files from previous aborted runs
    orb exec -m "$FORGEJO_VM" sudo rm -f /tmp/forgejo-backup.tar.gz /tmp/forgejo-db.sql

    # manually bundle the application data and repositories
    orb exec -m "$FORGEJO_VM" sudo tar -czf /tmp/forgejo-backup.tar.gz -C /var/lib/forgejo .

    # extract the raw database layout natively using pg_dump IF the database exists
    if orb exec -m "$FORGEJO_VM" sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw forgejo; then
        orb exec -m "$FORGEJO_VM" sudo -u postgres pg_dump -d forgejo -F p -f /tmp/forgejo-db.sql
    else
        log_info "'forgejo' database does not exist yet. Creating an empty fallback file."
        orb exec -m "$FORGEJO_VM" sudo touch /tmp/forgejo-db.sql
    fi

    # pull both backup artifacts to the Mac host
    orb exec -m "$FORGEJO_VM" sudo cat /tmp/forgejo-backup.tar.gz > "./forgejo-backup.tar.gz"
    orb exec -m "$FORGEJO_VM" sudo cat /tmp/forgejo-db.sql > "./forgejo-db.sql"
}

# remove the Tailscale node via the TS API and then clear the local Keychain cache
purge_ts_node() {
    local ts_oauth_secret_value
    ts_oauth_secret_value="$(security find-generic-password -s "$TS_OAUTH_SECRET_KEY" -w 2>/dev/null || true)"

    if [ -z "$ts_oauth_secret_value" ]; then
        log_err "'$TS_OAUTH_SECRET_KEY' secret not found in Keychain."
        exit 1
    fi

    # swap the client ID and secret for an ephemeral bearer access token
    local oauth_reply
    oauth_reply=$(curl -s -u "$TS_OAUTH_CLIENT_ID:$ts_oauth_secret_value" \
        -d "grant_type=client_credentials" \
        https://api.tailscale.com/api/v2/oauth/token)

    local access_token
    access_token=$(echo "$oauth_reply" | python3 -c "import sys, json; print(json.load(sys.stdin).get('access_token') or '')" 2>/dev/null)

    if [ -n "$access_token" ]; then
        local devices_json
        # query the device registry using the proper bearer authorization header
        devices_json=$(curl -s -H "Authorization: Bearer $access_token" \
            "https://api.tailscale.com/api/v2/tailnet/$TS_TAILNET/devices")

        local node_id
        node_id=$(echo "$devices_json" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    match = next((d['id'] for d in data.get('devices', []) if d.get('hostname', '').startswith('$FORGEJO_VM')), '')
    print(match)
except Exception:
    print('')
")

        # delete the Tailscale node registry entry if it exists
        if [ -n "$node_id" ]; then
            curl -s -X DELETE -H "Authorization: Bearer $access_token" \
                "https://api.tailscale.com/api/v2/device/$node_id" > /dev/null
            # Tailscale's coordination server uses an eventually consistent
            # distributed state model. When we delete a node via the API, the
            # global Magic DNS table holds an active lease/lock on the hostname
            # for up to 2 minutes. If we spin up the new VM immediately,
            # Tailscale detects a collision and appends a '-1' suffix (e.g.,
            # forgejo-appliance-1). Because tsbridge reads a static config
            # string and doesn't adapt to runtime hostnames, this suffix shift
            # breaks the internal TLS handshake loop, causing an infinite
            # 'context deadline exceeded' loop. The workaround is to wait for
            # 3 minutes to guarantee a clean slate.
            log_info "Waiting 3 minutes for Tailscale Magic DNS to flush and drop the hostname lease..."
            sleep 180
        else
            log_info "no active $FORGEJO_VM node found in Tailscale registry."
        fi
    fi

    # clear the local certificate cache so the next boot has a completely clean slate
    security delete-generic-password -s "$TS_CERT_CACHE" 2>/dev/null || true
}

# delete the underlying OrbStack VM instance
destroy_vm() {
    orb delete --force "$FORGEJO_VM" || true
}

main() {
    local purge_mode=0
    if [[ "$1" == "--purge" ]]; then
        purge_mode=1
    fi

    if [[ $purge_mode -eq 0 ]]; then
        backup_appliance_state
    else
        purge_ts_node
    fi

    destroy_vm
}

main "$@"
