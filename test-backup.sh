#!/bin/zsh

setopt ERR_EXIT
setopt PIPE_FAIL

# run from the appliance root
SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR"

source "./config.env"
source "./utils.sh"

TEST_ARCHIVE=""
SEED_USER=""

cleanup() {
    local exit_code=$?
    log_info "--> executing cleanup handler..."

    if [ -n "$TEST_ARCHIVE" ] && [ -n "$BORG_REPO" ]; then
        if borg info "::$TEST_ARCHIVE" >/dev/null 2>&1; then
            log_info "    deleting remote test archive '::$TEST_ARCHIVE'..."
            borg delete "::$TEST_ARCHIVE" >/dev/null 2>&1 || true
        fi
    fi

    if [ -n "$SEED_USER" ]; then
        if orb list 2>/dev/null | grep -qw "$FORGEJO_VM"; then
            log_info "    purging test user '$SEED_USER' from Forgejo..."
            orb exec -m "$FORGEJO_VM" sudo -u forgejo-admin \
                /home/forgejo-admin/bin/forgejo admin       \
                  user delete --username "$SEED_USER"       \
                              --purge -c /etc/forgejo/app.ini >/dev/null 2>&1 || true
        fi
    fi

    if [ $exit_code -eq 0 ]; then
        echo ""
        echo "=========================================="
        log_info "🏆 SUCCESS: Backup and restore pipeline validated end-to-end!"
        echo "=========================================="
    else
        log_err "Test failed with exit code $exit_code."
    fi
}

trap cleanup EXIT

main() {
    echo "=========================================="
    log_info "=== Starting Backup & Restore End-to-End Test ==="
    echo "=========================================="

    validate_borg_prerequisites

    # ensure appliance VM is running
    if ! orb list | grep -qw "$FORGEJO_VM"; then
        log_info "Appliance VM '$FORGEJO_VM' is not running. Bootstrapping fresh instance..."
        ./bootstrap-appliance.sh
    fi

    local timestamp="$(date +%s)"
    TEST_ARCHIVE="test-backup-$timestamp"
    SEED_USER="test_seed_$timestamp"
    local seed_pass="SeedPass_${timestamp}!"
    local seed_email="${SEED_USER}@test.local"
    local seed_repo="test-repo-$timestamp"
    local canary_user="test_canary_$timestamp"
    local canary_pass="CanaryPass_${timestamp}!"
    local canary_email="${canary_user}@test.local"

    # step 1: self-seed test data (user + git repo with commit)
    log_info "Step 1/5: Seeding test data in Forgejo..."
    log_info "    creating seed user '$SEED_USER'..."
    orb exec -m "$FORGEJO_VM" sudo -u forgejo-admin \
        /home/forgejo-admin/bin/forgejo admin       \
          user create --username "$SEED_USER"       \
                      --password "$seed_pass"       \
                      --email "$seed_email"         \
                      -c /etc/forgejo/app.ini >/dev/null

    log_info "    initializing test Git repository '$seed_repo' with initial commit..."
    orb exec -m "$FORGEJO_VM" curl -s -S -f -u "${SEED_USER}:${seed_pass}" \
        --unix-socket /run/forgejo/forgejo.sock \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"$seed_repo\",\"auto_init\":true,\"description\":\"Automated test repository\"}" \
        http://localhost/api/v1/user/repos >/dev/null

    # verify seed user and repository exist
    if ! orb exec -m "$FORGEJO_VM" sudo -u forgejo-admin \
        /home/forgejo-admin/bin/forgejo admin            \
          user list -c /etc/forgejo/app.ini 2>/dev/null | grep -qw "$SEED_USER"; then
        log_err "Failed to verify seed user '$SEED_USER' in database."
        exit 1
    fi
    local seed_user_lower="${(L)SEED_USER}"
    local seed_repo_lower="${(L)seed_repo}"
    if ! orb exec -m "$FORGEJO_VM" sudo test -d "/var/lib/forgejo/data/forgejo-repositories/${seed_user_lower}/${seed_repo_lower}.git"; then
        log_err "Failed to locate repository bare git directory on disk."
        exit 1
    fi
    log_info "✅ SEED: User and Git repository verified on appliance."

    # step 2: backup to custom archive
    echo ""
    log_info "Step 2/5: Creating snapshot '::$TEST_ARCHIVE' in Borg repo..."
    ./backup-appliance.sh "$TEST_ARCHIVE"

    log_info "    verifying snapshot in remote Borg repo..."
    if ! borg info "::$TEST_ARCHIVE" >/dev/null 2>&1; then
        log_err "Snapshot '::$TEST_ARCHIVE' not found in $BORG_REPO."
        exit 1
    fi
    log_info "✅ BACKUP: Snapshot verified in remote Borg repository."

    # step 3: divergence test (canary user created post-backup)
    echo ""
    log_info "Step 3/5: Introducing post-backup canary mutation..."
    orb exec -m "$FORGEJO_VM" sudo -u forgejo-admin \
        /home/forgejo-admin/bin/forgejo admin       \
          user create --username "$canary_user"     \
                      --password "$canary_pass"     \
                      --email "$canary_email"       \
                      -c /etc/forgejo/app.ini >/dev/null

    if ! orb exec -m "$FORGEJO_VM" sudo -u forgejo-admin \
        /home/forgejo-admin/bin/forgejo admin            \
          user list -c /etc/forgejo/app.ini 2>/dev/null | grep -qw "$canary_user"; then
        log_err "Failed to create canary user '$canary_user'."
        exit 1
    fi
    log_info "✅ DIVERGENCE: Canary user '$canary_user' injected into live appliance."

    # step 4: restore from snapshot
    echo ""
    log_info "Step 4/5: Restoring appliance from snapshot '::$TEST_ARCHIVE'..."
    ./restore-appliance.sh "$TEST_ARCHIVE"

    # step 5: verify restored integrity
    echo ""
    log_info "Step 5/5: Validating restored data integrity and state rollback..."

    # positive check: seed user
    if orb exec -m "$FORGEJO_VM" sudo -u forgejo-admin \
        /home/forgejo-admin/bin/forgejo admin user list -c /etc/forgejo/app.ini 2>/dev/null | grep -qw "$SEED_USER"; then
        log_info "✅ DATA INTEGRITY (Database): Seed user '$SEED_USER' survived restoration."
    else
        log_err "DATA INTEGRITY (Database): Seed user '$SEED_USER' not found after restore!"
        exit 1
    fi

    # positive check: git bare repo directory
    if orb exec -m "$FORGEJO_VM" sudo test -d "/var/lib/forgejo/data/forgejo-repositories/${seed_user_lower}/${seed_repo_lower}.git"; then
        log_info "✅ DATA INTEGRITY (Git Filesystem): Repository '$seed_repo' survived restoration."
    else
        log_err "DATA INTEGRITY (Git Filesystem): Repository directory '$seed_repo' missing after restore!"
        exit 1
    fi

    # negative check: canary user must NOT exist
    if orb exec -m "$FORGEJO_VM" sudo -u forgejo-admin \
        /home/forgejo-admin/bin/forgejo admin user list -c /etc/forgejo/app.ini 2>/dev/null | grep -qw "$canary_user"; then
        log_err "ROLLBACK INTEGRITY: Canary user '$canary_user' was found in restored database! State was not rolled back."
        exit 1
    else
        log_info "✅ ROLLBACK INTEGRITY: Canary user '$canary_user' is absent (state properly rolled back)."
    fi
}

main "$@"
