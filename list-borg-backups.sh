#!/bin/zsh

setopt ERR_EXIT
setopt PIPE_FAIL

# run script from the appliance root directory
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
