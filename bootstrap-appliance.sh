#!/bin/zsh

setopt ERR_EXIT

source "./config.env"
source "./utils.sh"

# fetch the Tailscale OAuth Client Secret from Apple Keychain
get_ts_secret() {
    TS_OAUTH_SECRET_VALUE="$(security find-generic-password -s "$TS_OAUTH_SECRET_KEY" -w 2>/dev/null)"
    if [ -z "$TS_OAUTH_SECRET_VALUE" ]; then
        log_err "'$TS_OAUTH_SECRET_KEY' not found in Keychain."
        exit 1
    fi
}

# create and initialize an OrbStack VM
provision_vm() {
    orb create ubuntu:26.04 "$FORGEJO_VM" --user-data "$FORGEJO_YAML"
    orb -m "$FORGEJO_VM" cloud-init status --wait || true
}

setup_tsbridge_reverse_proxy() {
    # create the tsbridge configuration directory and inject the OAuth credentials
    orb exec -m "$FORGEJO_VM" sudo mkdir -p /etc/tsbridge
    orb exec -m "$FORGEJO_VM" sudo sh -c "echo 'TS_OAUTH_CLIENT_ID=$TS_OAUTH_CLIENT_ID' > /etc/tsbridge/tsbridge.env"
    orb exec -m "$FORGEJO_VM" sudo sh -c "echo 'TS_OAUTH_CLIENT_SECRET=$TS_OAUTH_SECRET_VALUE' >> /etc/tsbridge/tsbridge.env"
    orb exec -m "$FORGEJO_VM" sudo chmod 0600 /etc/tsbridge/tsbridge.env
    orb exec -m "$FORGEJO_VM" sudo chown root:root /etc/tsbridge/tsbridge.env
    
    # restore the domain validation certificate from Apple Keychain
    local ts_state_b64
    ts_state_b64=$(security find-generic-password -s "$TS_CERT_CACHE" -w 2>/dev/null || true)

    if [ -n "$ts_state_b64" ]; then
        orb exec -m "$FORGEJO_VM" sudo mkdir -p /var/lib/tsbridge
        orb exec -m "$FORGEJO_VM" sudo chmod 700 /var/lib/tsbridge
        orb exec -m "$FORGEJO_VM" sudo chown root:root /var/lib/tsbridge
        printf "%s\n" "$ts_state_b64" | orb exec -m "$FORGEJO_VM" sudo sh -c 'base64 -d -i | tar -xf - -C /var/lib/tsbridge'
    fi
}

# halt the Forgejo service and restore certificates and Forgejo data from the macOS host
restore_appliance_data() {
    orb exec -m "$FORGEJO_VM" sudo systemctl stop forgejo

    # restore data (if a backup exists)
    if [ -f "./forgejo-backup.tar.gz" ] && [ -f "./forgejo-db.sql" ]; then
        # push both assets into the VM
        cat "./forgejo-backup.tar.gz" | orb exec -m "$FORGEJO_VM" sudo sh -c 'cat > /tmp/forgejo-backup.tar.gz'
        cat "./forgejo-db.sql" | orb exec -m "$FORGEJO_VM" sudo sh -c 'cat > /tmp/forgejo-db.sql'

        # ensure a clean destination layout exists inside the fresh VM
        orb exec -m "$FORGEJO_VM" sudo mkdir -p /var/lib/forgejo
        # unpack the flat tar stream directly into the target directory safely
        orb exec -m "$FORGEJO_VM" sudo tar -xzf /tmp/forgejo-backup.tar.gz -C /var/lib/forgejo/
        orb exec -m "$FORGEJO_VM" sudo chown -R forgejo-admin:forgejo-admin /var/lib/forgejo
        # loosen permissions for the database loader
        orb exec -m "$FORGEJO_VM" sudo chmod 644 /tmp/forgejo-db.sql

        # terminate active locks
        orb exec -m "$FORGEJO_VM" sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'forgejo';"
        # ensure the 'forgejo' role exists in the cluster before creating a DB for it
        orb exec -m "$FORGEJO_VM" sudo -u postgres psql -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'forgejo') THEN CREATE ROLE forgejo WITH LOGIN PASSWORD 'forgejo'; END IF; END \$\$;"
        
        orb exec -m "$FORGEJO_VM" sudo -u postgres dropdb --if-exists forgejo
        # drop the database and create a replacement owned by the forgejo user
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
    get_ts_secret
    provision_vm
    setup_tsbridge_reverse_proxy
    restore_appliance_data
    start_appliance_services
    unset TS_OAUTH_SECRET_VALUE
}

main "$@"
