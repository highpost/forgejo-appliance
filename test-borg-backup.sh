#!/bin/zsh

setopt ERR_EXIT
setopt PIPE_FAIL

# run script from the appliance root directory
SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR"

source "./config.env"
source "./utils.sh"

TEST_ARCHIVE=""
STASH_DIR=""

cleanup() {
    local exit_code=$?
    log_info "--> executing cleanup handler..."

    if [ -n "$TEST_ARCHIVE" ] && [ -n "$BORG_REPO" ]; then
        if borg info "::$TEST_ARCHIVE" >/dev/null 2>&1; then
            log_info "    deleting remote test archive '::$TEST_ARCHIVE'..."
            borg delete "::$TEST_ARCHIVE" >/dev/null 2>&1 || true
        fi
    fi

    if [ -n "$STASH_DIR" ] && [ -d "$STASH_DIR" ]; then
        log_info "    restoring original host backup files..."
        rm -f "./forgejo-backup.tar.gz" "./forgejo-db.sql" \
              "./forgejo-backup.tar.gz.bak" "./forgejo-db.sql.bak"
        for f in forgejo-backup.tar.gz forgejo-db.sql forgejo-backup.tar.gz.bak forgejo-db.sql.bak; do
            if [ -f "$STASH_DIR/$f" ]; then
                mv "$STASH_DIR/$f" "./$f"
            fi
        done
        rm -rf "$STASH_DIR"
    fi

    if [ $exit_code -eq 0 ]; then
        echo ""
        echo "=========================================="
        log_info "🏆 SUCCESS: Borg backup and restore pipeline validated end-to-end!"
        echo "=========================================="
    else
        log_err "Test failed with exit code $exit_code."
    fi
}

trap cleanup EXIT

main() {
    echo "=========================================="
    log_info "=== Starting Borg Backup & Restore End-to-End Test ==="
    echo "=========================================="

    validate_borg_prerequisites

    local timestamp="$(date +%s)"
    TEST_ARCHIVE="test-borg-backup-$timestamp"
    STASH_DIR="$(mktemp -d)"

    # stash any pre-existing host backup files so the test is non-destructive
    for f in forgejo-backup.tar.gz forgejo-db.sql forgejo-backup.tar.gz.bak forgejo-db.sql.bak; do
        if [ -f "./$f" ]; then
            mv "./$f" "$STASH_DIR/$f"
        fi
    done

    # step 1: generate synthetic backup artifacts and record checksums
    log_info "Step 1/5: Generating test backup artifacts (forgejo-backup.tar.gz and forgejo-db.sql)..."
    local payload_dir="$STASH_DIR/payload"
    mkdir -p "$payload_dir/repositories/test.git"
    echo "ref: refs/heads/main ($timestamp)" > "$payload_dir/repositories/test.git/HEAD"
    tar -czf "./forgejo-backup.tar.gz" -C "$payload_dir" .
    rm -rf "$payload_dir"

    cat <<EOF > "./forgejo-db.sql"
-- Forgejo test SQL dump ($timestamp)
CREATE TABLE test_seed (id INT PRIMARY KEY, label TEXT);
INSERT INTO test_seed VALUES (1, 'seed-$timestamp');
EOF

    local expected_tar_hash
    local expected_sql_hash
    expected_tar_hash=$(shasum -a 256 "./forgejo-backup.tar.gz" | awk '{print $1}')
    expected_sql_hash=$(shasum -a 256 "./forgejo-db.sql" | awk '{print $1}')
    log_info "    forgejo-backup.tar.gz SHA-256: $expected_tar_hash"
    log_info "    forgejo-db.sql        SHA-256: $expected_sql_hash"
    log_info "✅ SEED: Test backup artifacts generated on host."

    # step 2: push snapshot to Borg repository
    echo ""
    log_info "Step 2/5: Creating snapshot '::$TEST_ARCHIVE' in Borg repo..."
    ./borg-backup.sh "$TEST_ARCHIVE"

    log_info "    verifying snapshot via list-borg-backups.sh..."
    if ! ./list-borg-backups.sh | grep -qw "$TEST_ARCHIVE"; then
        log_err "Snapshot '$TEST_ARCHIVE' not found in list-borg-backups.sh output."
        exit 1
    fi
    log_info "✅ BACKUP: Snapshot verified in remote Borg repository."

    # step 3: mutate local files to simulate state divergence / corruption
    echo ""
    log_info "Step 3/5: Mutating local host artifacts to simulate divergence..."
    echo "mutated-tar-content-$timestamp" > "./forgejo-backup.tar.gz"
    echo "-- mutated SQL content ($timestamp)" > "./forgejo-db.sql"

    local mutated_tar_hash
    local mutated_sql_hash
    mutated_tar_hash=$(shasum -a 256 "./forgejo-backup.tar.gz" | awk '{print $1}')
    mutated_sql_hash=$(shasum -a 256 "./forgejo-db.sql" | awk '{print $1}')

    if [ "$mutated_tar_hash" = "$expected_tar_hash" ] || [ "$mutated_sql_hash" = "$expected_sql_hash" ]; then
        log_err "Failed to mutate local host artifacts."
        exit 1
    fi
    log_info "✅ DIVERGENCE: Local host artifacts mutated."

    # step 4: restore from Borg snapshot
    echo ""
    log_info "Step 4/5: Restoring artifacts from snapshot '::$TEST_ARCHIVE'..."
    ./borg-restore.sh "$TEST_ARCHIVE"

    # step 5: verify restored file checksums and .bak preservation
    echo ""
    log_info "Step 5/5: Validating restored artifact checksums and .bak preservation..."

    local restored_tar_hash
    local restored_sql_hash
    restored_tar_hash=$(shasum -a 256 "./forgejo-backup.tar.gz" | awk '{print $1}')
    restored_sql_hash=$(shasum -a 256 "./forgejo-db.sql" | awk '{print $1}')

    if [ "$restored_tar_hash" = "$expected_tar_hash" ]; then
        log_info "✅ DATA INTEGRITY (Archive): forgejo-backup.tar.gz checksum matches original."
    else
        log_err "DATA INTEGRITY (Archive): Checksum mismatch! Expected $expected_tar_hash, got $restored_tar_hash."
        exit 1
    fi

    if [ "$restored_sql_hash" = "$expected_sql_hash" ]; then
        log_info "✅ DATA INTEGRITY (Database): forgejo-db.sql checksum matches original."
    else
        log_err "DATA INTEGRITY (Database): Checksum mismatch! Expected $expected_sql_hash, got $restored_sql_hash."
        exit 1
    fi

    if [ -f "./forgejo-backup.tar.gz.bak" ] && [ -f "./forgejo-db.sql.bak" ]; then
        log_info "✅ ROLLBACK SAFETY: Diverged host files preserved as .bak."
    else
        log_err "ROLLBACK SAFETY: Expected .bak files were not created during restore!"
        exit 1
    fi
}

main "$@"
