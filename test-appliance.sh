#!/bin/zsh

setopt ERR_EXIT

source "./config.env"
source "./utils.sh"

TARGET_IP=""  # global variable to hold the resolved IP for downstream tests
TARGET_HOST="$TS_HOSTNAME.$TS_TAILNET"
TOTAL_CYCLES=10

# tear down and bootstrap a fresh VM
rebuild_appliance() {
    log_info "--> running teardown and extracting state..."
    ./teardown-appliance.sh || { log_err "teardown-appliance.sh failed"; exit 1; }

    log_info "--> bootstrapping fresh appliance..."
    ./bootstrap-appliance.sh || { log_err "bootstrap-appliance.sh failed"; exit 1; }
}

# wait for Tailscale convergence (smart polling)
resolve_tailscale_ip() {
    log_info "--> waiting for Tailscale convergence..."
    TARGET_IP=""
    
    local poll
    for poll in {1..10}; do
        # || true prevents grep from killing the script if it finds nothing
        TARGET_IP=$(tailscale status | grep -w "$TS_HOSTNAME" | awk '{print $1}' || true)

        if [ -n "$TARGET_IP" ]; then
            break
        fi
        log_info "    ... still waiting for node to appear in Mac's Tailnet registry (attempt $poll/10)..."
        sleep 5
    done

    if [ -z "$TARGET_IP" ]; then
        log_err "could not find Tailscale IP for $TS_HOSTNAME after 50 seconds."
        exit 1
    fi

    log_info "--> resolved internal IP via Tailscale: $TARGET_IP"
}

# verification test - Tailscale ping (wait for tunnel)
verify_tunnel() {
    log_info "--> establishing WireGuard tunnel (Tailscale ping)..."
    local ping_success=0
    
    local p
    for p in {1..10}; do
        if tailscale ping -c 1 --timeout=2s "$TS_HOSTNAME" > /dev/null 2>&1; then
            ping_success=1
            break
        fi
        log_info "    ... negotiating tunnel (attempt $p/10)..."
        sleep 2
    done

    if [ $ping_success -eq 1 ]; then
        log_info "✅ PING: success"
    else
        log_err "PING: failed to establish tunnel."
        exit 1
    fi
}

# verification test - HTTPS curl (wait for Let's Encrypt / TLS)
verify_https() {
    log_info "--> testing HTTPS certificate and proxy..."
    local curl_success=0
    
    local c
    for c in {1..10}; do
        if curl -fsSL -I --resolve "$TARGET_HOST:443:$TARGET_IP" "https://$TARGET_HOST" > /dev/null 2>&1; then
            curl_success=1
            break
        fi
        log_info "    ... waiting for TLS proxy to serve certificate (attempt $c/10)..."
        sleep 3
    done

    if [ $curl_success -eq 1 ]; then
        log_info "✅ HTTPS: success (certificate accepted!)"
    else
        log_err "HTTPS: failed (proxy down, cert invalid or rate limited)"
        exit 1
    fi
}

# verification test - data persistence
verify_persistence() {
    local cycle_num="$1"
    log_info "--> testing data persistence..."
    
    # use the internal Forgejo CLI to check if the database survived
    if orb exec -m "$FORGEJO_VM" sudo -u forgejo-admin /home/forgejo-admin/bin/forgejo admin user list -c /etc/forgejo/app.ini 2>/dev/null | grep -q "stresstest"; then
        log_info "✅ DATA: success ('stresstest' user survived the rebuild!)"
    else
        if [ "$cycle_num" -eq 1 ]; then
            log_info "ℹ️  DATA: cycle 1 - creating 'stresstest' user for subsequent cycles..."
            orb exec -m "$FORGEJO_VM" sudo -u forgejo-admin /home/forgejo-admin/bin/forgejo admin user create \
              --username stresstest \
              --password 'PersistenceTest123!' \
              --email stress@example.com \
              -c /etc/forgejo/app.ini > /dev/null 2>&1
        else
            log_err "DATA: failed (database was wiped or not restored properly)"
            exit 1
        fi
    fi
}

main() {
    echo "=========================================="
    log_info "=== starting lifecycle stress test ==="
    log_info "target: $TARGET_HOST"
    log_info "iterations: $TOTAL_CYCLES"
    echo "=========================================="

    local i
    for ((i=1; i<=TOTAL_CYCLES; i++)); do
        echo ""
        echo "--------------------------------------------------"
        log_info "🔄 STARTING CYCLE $i of $TOTAL_CYCLES"
        echo "--------------------------------------------------"

        rebuild_appliance
        resolve_tailscale_ip
        verify_tunnel
        verify_https
        verify_persistence "$i"

        echo ""
        log_info "🎉 cycle $i completed successfully!"
    done

    echo ""
    echo "=========================================="
    log_info "🏆 SUCCESS: appliance validated over $TOTAL_CYCLES cycles!"
    echo "=========================================="
}

main "$@"
