#!/bin/zsh

setopt ERR_EXIT

# logging helpers
log_info() {
    echo "[$(date +'%H:%M:%S')] ℹ️  $*"
}

log_err() {
    echo "[$(date +'%H:%M:%S')] ❌ ERROR: $*" >&2
}

if [ -n "$SSH_CLIENT" ] || [ -n "$SSH_TTY" ]; then
    log_err "Execution blocked. The macOS Security Framework prevents Keychain write access via SSH."
    exit 1
fi

validate_borg_prerequisites() {
    if ! command -v borg >/dev/null 2>&1; then
        log_err "BorgBackup is not installed on the macOS host. Run 'brew install borgbackup' first."
        exit 1
    fi

    if [ -z "$BORG_REPO" ]; then
        log_err "BORG_REPO is not set. Configure BORG_REPO in config.env."
        exit 1
    fi
    export BORG_REPO

    # ensure Borg passphrase command is configured without leaking secrets into the environment
    if [ -z "$BORG_PASSCOMMAND" ] && [ -z "$BORG_PASSPHRASE" ]; then
        if ! security find-generic-password -s "$BORG_PASSPHRASE_KEY" >/dev/null 2>&1; then
            log_err "Borg passphrase not found in Apple Keychain (service '$BORG_PASSPHRASE_KEY')."
            log_err "Run './store-borg-passphrase.sh' to store your passphrase in Keychain."
            exit 1
        fi
        export BORG_PASSCOMMAND="security find-generic-password -s $BORG_PASSPHRASE_KEY -w"
    fi
}
