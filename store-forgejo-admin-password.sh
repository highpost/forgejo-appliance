#!/bin/zsh

setopt ERR_EXIT

source "./config.env"
source "./utils.sh"

# Store the Forgejo administrator password in Apple Keychain.
echo -n "enter the Forgejo administrator password: " && read -rs FORGEJO_ADMIN_PASSWORD_VALUE
echo ""

if [ -z "$FORGEJO_ADMIN_PASSWORD_VALUE" ]; then
    log_err "Forgejo administrator password cannot be empty."
    exit 1
fi

security add-generic-password                   \
           -a "$USER"                           \
           -s "$FORGEJO_ADMIN_PASSWORD_KEY"     \
           -w "$FORGEJO_ADMIN_PASSWORD_VALUE"   \
           -U

unset FORGEJO_ADMIN_PASSWORD_VALUE

log_info "Forgejo administrator password securely stored in Keychain under '$FORGEJO_ADMIN_PASSWORD_KEY'."

