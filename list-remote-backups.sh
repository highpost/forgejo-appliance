#!/bin/zsh

setopt ERR_EXIT
setopt PIPE_FAIL

# ensure operations run from the appliance repository root
SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR"

source "./config.env"
source "./utils.sh"

main() {
    validate_borg_prerequisites

    log_info "Querying remote backups from: $BORG_REPO"
    echo ""
    borg list "$@"
    echo ""
}

main "$@"
