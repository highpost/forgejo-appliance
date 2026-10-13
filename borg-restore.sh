#!/bin/zsh

setopt ERR_EXIT
setopt PIPE_FAIL

# run script from the appliance root directory
SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR"

source "./config.env"
source "./utils.sh"

main() {
    local target_archive="${1#::}"

    if [ -z "$target_archive" ]; then
        log_err "Missing archive name."
        echo "Usage: ./borg-restore.sh <archive_name>"
        echo ""
        log_info "Listing available remote backups:"
        ./list-borg-backups.sh
        exit 1
    fi

    validate_borg_prerequisites

    log_info "Checking archive '::$target_archive' in Borg backup repo..."
    if ! borg info "::$target_archive" >/dev/null 2>&1; then
        log_err "Archive '::$target_archive' not found in $BORG_REPO."
        echo ""
        log_info "Available remote backups:"
        borg list
        exit 1
    fi

    # create isolated staging directory for extraction
    local stage_dir
    stage_dir="$(mktemp -d)"
    trap 'rm -rf "$stage_dir"' EXIT

    log_info "Step 1/2: Extracting archive '::$target_archive' to staging directory..."
    (
        cd "$stage_dir"
        borg extract "::$target_archive"
    )

    # locate extracted backup artifacts
    local extracted_tar
    local extracted_sql
    extracted_tar=$(find "$stage_dir" -type f -name "forgejo-backup.tar.gz" | head -n 1)
    extracted_sql=$(find "$stage_dir" -type f -name "forgejo-db.sql" | head -n 1)

    if [ -z "$extracted_tar" ] || [ ! -s "$extracted_tar" ]; then
        log_err "Archive '::$target_archive' does not contain a valid forgejo-backup.tar.gz."
        exit 1
    fi

    if [ -z "$extracted_sql" ]; then
        log_err "Archive '::$target_archive' does not contain forgejo-db.sql."
        exit 1
    fi

    log_info "Step 2/2: Restoring backup files to host..."
    # preserve current host artifacts as .bak if present
    if [ -f "./forgejo-backup.tar.gz" ]; then
        cp "./forgejo-backup.tar.gz" "./forgejo-backup.tar.gz.bak"
    fi
    if [ -f "./forgejo-db.sql" ]; then
        cp "./forgejo-db.sql" "./forgejo-db.sql.bak"
    fi

    cp "$extracted_tar" "./forgejo-backup.tar.gz"
    cp "$extracted_sql" "./forgejo-db.sql"

    log_info "Backup files restored from archive '::$target_archive'!"
}

main "$@"
