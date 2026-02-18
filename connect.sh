#!/bin/bash
# connect.sh — Connect to a test machine from any other machine
#
# Usage:
#   bash connect.sh setup IP [USER]   # Configure SSH
#   bash connect.sh test              # Test connection
#   bash connect.sh deploy            # Upload this repo
#   bash connect.sh ssh               # Interactive shell
#   bash connect.sh run-test          # Run E2E tests remotely
#   bash connect.sh status            # Check agent status
#   bash connect.sh tunnel            # Port-forward agent API
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_DIR
readonly SSH_ALIAS="kvm-test"
readonly AGENT_PORT=8420
CONF_FILE="${SCRIPT_DIR}/.connect.conf"

log()  { echo "[connect] $*"; }
info() { echo "[connect]   $*"; }

load_conf() {
    if [[ -f "$CONF_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONF_FILE"
    fi
}

cmd_setup() {
    local ip="${1:?Usage: $0 setup IP [USER]}"
    local user="${2:-$(whoami)}"

    log "Configuring SSH for $user@$ip"

    mkdir -p ~/.ssh
    chmod 700 ~/.ssh

    if [[ ! -f ~/.ssh/id_ed25519 ]]; then
        ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "qubes-kvm-test"
    fi

    local ssh_conf=~/.ssh/config
    if ! grep -q "Host ${SSH_ALIAS}" "$ssh_conf" 2>/dev/null; then
        cat >> "$ssh_conf" << SSHEOF

Host ${SSH_ALIAS}
    HostName ${ip}
    User ${user}
    Port 22
    ForwardAgent yes
    ServerAliveInterval 30
    ServerAliveCountMax 5
    LocalForward ${AGENT_PORT} localhost:${AGENT_PORT}
SSHEOF
        chmod 600 "$ssh_conf"
        log "  Added '${SSH_ALIAS}' to SSH config"
    else
        log "  '${SSH_ALIAS}' already in SSH config — updating IP"
        sed -i "/Host ${SSH_ALIAS}/,/^Host /{s/HostName .*/HostName ${ip}/}" "$ssh_conf"
        sed -i "/Host ${SSH_ALIAS}/,/^Host /{s/User .*/User ${user}/}" "$ssh_conf"
    fi

    echo "TARGET_IP=${ip}" > "$CONF_FILE"
    echo "TARGET_USER=${user}" >> "$CONF_FILE"

    log "  SSH alias: ${SSH_ALIAS}"
    log "  Connect: ssh ${SSH_ALIAS}"
    log ""
    log "  Copy your key: ssh-copy-id ${SSH_ALIAS}"
}

cmd_test() {
    load_conf
    log "Testing SSH connection to ${SSH_ALIAS}..."

    if ssh -o ConnectTimeout=5 "${SSH_ALIAS}" "echo SSH_OK; hostname; uname -m; cat /proc/cpuinfo | grep -c processor" 2>/dev/null; then
        log "Connection: OK"
    else
        log "Connection: FAILED"
        info "Run: $0 setup IP [USER]"
        return 1
    fi
}

cmd_deploy() {
    load_conf
    log "Deploying test repo to ${SSH_ALIAS}..."

    local remote_dir="~/qubes-kvm-test"
    ssh "${SSH_ALIAS}" "mkdir -p ${remote_dir}"

    rsync -avz --delete \
        --exclude '.git' \
        --exclude 'agent/.venv' \
        --exclude 'vm-images/*.qcow2' \
        --exclude 'test/results' \
        --exclude '.connect.conf' \
        "$SCRIPT_DIR/" "${SSH_ALIAS}:${remote_dir}/"

    log "Deployed to ${SSH_ALIAS}:${remote_dir}"
    log "  Run remotely: ssh ${SSH_ALIAS} 'cd ${remote_dir} && bash run-all.sh'"
}

cmd_ssh() {
    exec ssh "${SSH_ALIAS}"
}

cmd_run_test() {
    load_conf
    log "Running E2E tests on ${SSH_ALIAS}..."
    ssh "${SSH_ALIAS}" "cd ~/qubes-kvm-test && bash run-all.sh test"
}

cmd_status() {
    load_conf
    log "Checking agent on ${SSH_ALIAS}..."
    ssh "${SSH_ALIAS}" "curl -sf http://localhost:${AGENT_PORT}/status 2>/dev/null | python3 -m json.tool || echo 'Agent not running'"
}

cmd_tunnel() {
    load_conf
    log "Starting SSH tunnel (agent API at localhost:${AGENT_PORT})..."
    info "Press Ctrl+C to stop"
    ssh -N -L "${AGENT_PORT}:localhost:${AGENT_PORT}" "${SSH_ALIAS}"
}

# ── Main ─────────────────────────────────────────────────────────

case "${1:-help}" in
    setup)     shift; cmd_setup "$@" ;;
    test)      cmd_test ;;
    deploy)    cmd_deploy ;;
    ssh)       cmd_ssh ;;
    run-test)  cmd_run_test ;;
    status)    cmd_status ;;
    tunnel)    cmd_tunnel ;;
    *)
        echo "Usage: $(basename "$0") <command> [args]"
        echo ""
        echo "Commands:"
        echo "  setup IP [USER]  Configure SSH connection"
        echo "  test             Test SSH connectivity"
        echo "  deploy           Upload repo to remote machine"
        echo "  ssh              Interactive shell"
        echo "  run-test         Run E2E tests remotely"
        echo "  status           Check agent status"
        echo "  tunnel           Port-forward agent API"
        ;;
esac
