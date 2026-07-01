#!/bin/zsh

setopt ERR_EXIT

# logging helpers
log_info() {
    echo "[$(date +'%H:%M:%S')] ℹ️  $*"
}

log_err() {
    echo "[$(date +'%H:%M:%S')] ❌ ERROR: $*" >&2
}

# The macOS Security Framework blocks Keychain write access via SSH.
if [ -n "$SSH_CLIENT" ] || [ -n "$SSH_TTY" ]; then
    log_err "Execution blocked. You must run this script from a local terminal, not via SSH."
    exit 1
fi
