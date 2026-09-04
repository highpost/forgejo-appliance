#!/bin/zsh

setopt ERR_EXIT

source "./config.env"
source "./utils.sh"

# Store the Tailscale OAuth Client Secret in Apple Keychain.
# https://login.tailscale.com/admin/settings/oauth (Settings -> Trust credentials)
echo -n "enter the Tailscale OAuth Client Secret (tskey-client-...): " && read -rs TS_OAUTH_SECRET_VALUE
echo ""

if [ -z "$TS_OAUTH_SECRET_VALUE" ]; then
    log_err "Tailscale OAuth client secret cannot be empty."
    exit 1
fi

security add-generic-password           \
           -a "$USER"                   \
           -s "$TS_OAUTH_SECRET_KEY"    \
           -w "$TS_OAUTH_SECRET_VALUE"  \
           -U

unset TS_OAUTH_SECRET_VALUE

log_info "Tailscale OAuth Client Secret securely stored in Keychain under '$TS_OAUTH_SECRET_KEY'."
