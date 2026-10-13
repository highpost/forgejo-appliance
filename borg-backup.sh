#!/bin/zsh

setopt ERR_EXIT
setopt PIPE_FAIL

# run from the appliance root
SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR"

source "./config.env"
source "./utils.sh"

main() {
    validate_borg_prerequisites

    if [ ! -f "./forgejo-backup.tar.gz" ] || [ ! -f "./forgejo-db.sql" ]; then
        log_err "Backup artifacts (./forgejo-backup.tar.gz and ./forgejo-db.sql) not found on host."
        log_err "Run ./teardown-appliance.sh first to extract the appliance state."
        exit 1
    fi

    log_info "Creating encrypted deduplicated snapshot in Borg repo..."
    local archive_name="${1:-$BORG_ARCHIVE_NAME}"
    local archive_target="${archive_name:-::{now:%Y-%m-%d}}"
    if [[ "$archive_target" != *"::"* ]]; then
        archive_target="::$archive_target"
    fi

    borg create --stats "$archive_target" ./forgejo-backup.tar.gz ./forgejo-db.sql

    if [ -z "$1" ]; then
        local prune_flags=()
        if [ -n "$BORG_RETENTION_POLICY" ]; then
            prune_flags=(${=BORG_RETENTION_POLICY})
            log_info "Pruning old archives with custom policy: $BORG_RETENTION_POLICY"
        else
            [ -n "$BORG_KEEP_DAILY" ]   && prune_flags+=(--keep-daily="$BORG_KEEP_DAILY")
            [ -n "$BORG_KEEP_WEEKLY" ]  && prune_flags+=(--keep-weekly="$BORG_KEEP_WEEKLY")
            [ -n "$BORG_KEEP_MONTHLY" ] && prune_flags+=(--keep-monthly="$BORG_KEEP_MONTHLY")
            [ -n "$BORG_KEEP_YEARLY" ]  && prune_flags+=(--keep-yearly="$BORG_KEEP_YEARLY")
            log_info "Pruning old archives (keeping ${BORG_KEEP_DAILY:-0} daily, ${BORG_KEEP_WEEKLY:-0} weekly, ${BORG_KEEP_MONTHLY:-0} monthly)..."
        fi

        borg prune "${prune_flags[@]}"
    fi

    log_info "🎉 Borg backup completed successfully!"
}

main "$@"
