#!/bin/zsh

setopt ERR_EXIT

source "./config.env"
source "./utils.sh"

# create and initialize an OrbStack VM
provision_vm() {
    orb create ubuntu:26.04 "$FORGEJO_VM" --user-data "$FORGEJO_YAML"
    orb -m "$FORGEJO_VM" cloud-init status --wait || true
}

setup_tsbridge_reverse_proxy() {
    # fetch the Tailscale OAuth client secret from Apple Keychain
    local ts_oauth_secret_value
    ts_oauth_secret_value="$(security find-generic-password -s "$TS_OAUTH_SECRET_KEY" -w 2>/dev/null)"
    if [ -z "$ts_oauth_secret_value" ]; then
        log_err "'$TS_OAUTH_SECRET_KEY' not found in Keychain."
        exit 1
    fi

    # create the tsbridge configuration directory and inject the OAuth credentials
    orb exec -m "$FORGEJO_VM" sudo mkdir -p /etc/tsbridge
    orb exec -m "$FORGEJO_VM" sudo sh <<EOF
      echo 'TS_OAUTH_CLIENT_ID=$TS_OAUTH_CLIENT_ID'         > /etc/tsbridge/tsbridge.env
      echo 'TS_OAUTH_CLIENT_SECRET=$ts_oauth_secret_value' >> /etc/tsbridge/tsbridge.env
EOF
    unset ts_oauth_secret_value
    orb exec -m "$FORGEJO_VM" sudo chmod 0600      /etc/tsbridge/tsbridge.env
    orb exec -m "$FORGEJO_VM" sudo chown root:root /etc/tsbridge/tsbridge.env

    # restore the WireGuard node private key and ACME TLS certificate from Apple Keychain
    local state_key="${TS_STATE_CACHE:-${TS_CERT_CACHE:-tsbridge-state-cache}}"
    local ts_state_b64
    ts_state_b64=$(security find-generic-password -s "$state_key" -w 2>/dev/null || true)
    if [ -z "$ts_state_b64" ] && [ "$state_key" != "tsbridge-cert-cache" ]; then
        # legacy fallback
        ts_state_b64=$(security find-generic-password -s "tsbridge-cert-cache" -w 2>/dev/null || true)
    fi

    # decode and unpack the cached WireGuard node identity and ACME TLS certificates into /var/lib/tsbridge
    if [ -n "$ts_state_b64" ]; then
        orb exec -m "$FORGEJO_VM" sudo mkdir -p        /var/lib/tsbridge
        orb exec -m "$FORGEJO_VM" sudo chmod 700       /var/lib/tsbridge
        orb exec -m "$FORGEJO_VM" sudo chown root:root /var/lib/tsbridge
        printf "%s\n" "$ts_state_b64" | orb exec -m "$FORGEJO_VM" sudo sh -c '
          base64 -d -i | tar -xf - -C /var/lib/tsbridge'
    fi
}

# halt the Forgejo service and restore certificates and Forgejo data from the macOS host
restore_appliance_data() {
    orb exec -m "$FORGEJO_VM" sudo systemctl stop forgejo

    # restore data (if a backup exists)
    if [ -f "./forgejo-backup.tar.gz" ] && [ -f "./forgejo-db.sql" ]; then
        # push both assets into the VM
        cat "./forgejo-backup.tar.gz" | orb exec -m "$FORGEJO_VM" sudo sh -c 'cat > /tmp/forgejo-backup.tar.gz'
        cat "./forgejo-db.sql"        | orb exec -m "$FORGEJO_VM" sudo sh -c 'cat > /tmp/forgejo-db.sql'

        # ensure a clean destination layout exists inside the fresh VM
        orb exec -m "$FORGEJO_VM" sudo mkdir -p /var/lib/forgejo
        orb exec -m "$FORGEJO_VM" sudo tar -xzf /tmp/forgejo-backup.tar.gz -C /var/lib/forgejo/
        orb exec -m "$FORGEJO_VM" sudo chown -R forgejo-admin:forgejo-admin /var/lib/forgejo
        orb exec -m "$FORGEJO_VM" sudo chmod 644 /tmp/forgejo-db.sql

        # terminate any active locks and ensure the 'forgejo' role exists
        # NB: the closing EOF string must be at the beginning of the line
        # or we need to replace spaces with tabs.
        orb exec -m "$FORGEJO_VM" sudo -u postgres psql <<'EOF'
          SELECT pg_terminate_backend(pid)
          FROM pg_stat_activity
          WHERE datname = 'forgejo';

          DO $$
          BEGIN
            IF NOT EXISTS (
              SELECT FROM pg_catalog.pg_roles WHERE rolname = 'forgejo'
            ) THEN
              CREATE ROLE forgejo WITH LOGIN PASSWORD 'forgejo';
            END IF;
          END $$;
EOF

        # drop the database and create a replacement owned by the forgejo user
        orb exec -m "$FORGEJO_VM" sudo -u postgres dropdb --if-exists forgejo
        orb exec -m "$FORGEJO_VM" sudo -u postgres createdb -O forgejo forgejo

        # only load the database layout if the SQL file contains active snapshot statements
        if orb exec -m "$FORGEJO_VM" sudo test -s /tmp/forgejo-db.sql; then
            orb exec -m "$FORGEJO_VM" sudo -u postgres psql -d forgejo -f /tmp/forgejo-db.sql > /dev/null
        fi
    fi
}

# start the Forgejo/tsbridge services and verify UNIX socket health
start_appliance_services() {
    orb exec -m "$FORGEJO_VM" sudo systemctl daemon-reload
    orb exec -m "$FORGEJO_VM" sudo systemctl start forgejo

    # wait for the volatile socket file to be added to the filesystem
    sleep 4

    # ensure socket permissions match bridge transit requirements
    if orb exec -m "$FORGEJO_VM" sudo test -S /run/forgejo/forgejo.sock; then
        orb exec -m "$FORGEJO_VM" sudo chmod 755 /run/forgejo
        orb exec -m "$FORGEJO_VM" sudo chmod 666 /run/forgejo/forgejo.sock
    else
        log_err "Forgejo failed to initialize its UNIX socket file."
        orb exec -m "$FORGEJO_VM" sudo journalctl -u forgejo.service -n 20 --no-pager
        exit 1
    fi

    # start the Tailscale-aware reverse proxy
    orb exec -m "$FORGEJO_VM" sudo systemctl restart tsbridge
}

main() {
    provision_vm
    setup_tsbridge_reverse_proxy
    restore_appliance_data
    start_appliance_services
}

main "$@"
