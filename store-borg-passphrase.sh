#!/bin/zsh

setopt ERR_EXIT

source "./config.env"
source "./utils.sh"

# Store the Borg backup repo passphrase in Apple Keychain.
echo -n "enter the Borg backup repo passphrase: " && read -rs BORG_PASSPHRASE_VALUE
echo ""

if [ -z "$BORG_PASSPHRASE_VALUE" ]; then
    log_err "Borg backup repo passphrase cannot be empty."
    exit 1
fi

security add-generic-password           \
           -a "$USER"                   \
           -s "$BORG_PASSPHRASE_KEY"    \
           -w "$BORG_PASSPHRASE_VALUE"  \
           -U

unset BORG_PASSPHRASE_VALUE

log_info "Borg passphrase securely stored in Keychain under '$BORG_PASSPHRASE_KEY'."
