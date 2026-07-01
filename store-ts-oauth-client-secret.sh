#!/bin/zsh

setopt ERR_EXIT

source "./config.env"

# Copy a Tailscale OAuth Client Secret from the system clipboard to Apple Keychain.
# https://login.tailscale.com/admin/settings/oauth (Settings -> Trust credentials)
echo -n "paste the Tailscale OAuth Client Secret (tskey-client-...): " && read -rs TS_OAUTH_SECRET_VALUE

security add-generic-password           \
           -a "$USER"                   \
           -s "$TS_OAUTH_SECRET_KEY"    \
           -w "$TS_OAUTH_SECRET_VALUE"  \
           -U

unset TS_OAUTH_SECRET_VALUE
