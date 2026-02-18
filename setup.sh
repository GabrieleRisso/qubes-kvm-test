#!/bin/bash
# setup.sh — Machine setup for Qubes KVM fork testing
#
# Uses: pacman (selective, no full upgrade), yay (AUR), uv (Python)
# Target: EndeavourOS / Arch Linux with KVM
#
# Usage:
#   bash setup.sh              # Full setup
#   bash setup.sh --check      # Verify readiness
#   bash setup.sh --agent      # Agent service only
#   bash setup.sh --deps       # Install dependencies only
#   bash setup.sh --kvm        # KVM + nested virt only
#   bash setup.sh --fix-glibc  # Fix specific package mismatches
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_DIR
readonly AGENT_DIR="${SCRIPT_DIR}/agent"
readonly VENV_DIR="${AGENT_DIR}/.venv"
CURRENT_USER="$(whoami)"
readonly CURRENT_USER
HOME_DIR="$(eval echo ~)"
readonly HOME_DIR

log()  { echo "[setup] $*"; }
info() { echo "[setup]   $*"; }
warn() { echo "[setup] WARNING: $*"; }
err()  { echo "[setup] ERROR: $*" >&2; }

# ── Hardware check ────────────────────────────────────────────────

check_hardware() {
    log "=== Hardware Check ==="

    if [[ -e /dev/kvm ]]; then
        log "  /dev/kvm: present"
    else
        warn "/dev/kvm not found — enable VT-x/AMD-V in BIOS"
    fi

    local cpu_vendor="unknown"
    if grep -q "GenuineIntel" /proc/cpuinfo 2>/dev/null; then
        cpu_vendor="intel"
    elif grep -q "AuthenticAMD" /proc/cpuinfo 2>/dev/null; then
        cpu_vendor="amd"
    fi

    log "  CPU: ${cpu_vendor} ($(nproc) cores)"
    log "  RAM: $(awk '/MemTotal/{printf "%.0f GB", $2/1024/1024}' /proc/meminfo)"
    log "  Kernel: $(uname -r)"

    if [[ -f /etc/endeavouros-release ]]; then
        log "  Distro: EndeavourOS"
    elif [[ -f /etc/arch-release ]]; then
        log "  Distro: Arch Linux"
    else
        warn "Not Arch-based — pacman/yay commands need adjustment"
    fi
}

# ── Selective package install (NO full upgrade) ───────────────────

install_deps() {
    log "=== Installing Dependencies (selective, no -Syu) ==="

    log "Syncing package database..."
    sudo pacman -Sy --noconfirm

    log "Installing core build + virtualization packages..."
    sudo pacman -S --needed --noconfirm \
        base-devel git cmake meson ninja \
        python python-pip python-virtualenv python-setuptools \
        qemu-base qemu-system-x86 qemu-system-aarch64 qemu-img \
        libvirt virt-manager dnsmasq iptables-nft nftables \
        podman buildah skopeo \
        edk2-ovmf swtpm \
        openssh wget curl jq rsync tmux htop \
        shellcheck rust rpm-tools \
        pciutils usbutils lshw \
        2>&1 | tail -5

    log "Installing ARM64 cross-compilation tools..."
    sudo pacman -S --needed --noconfirm \
        aarch64-linux-gnu-gcc aarch64-linux-gnu-binutils \
        2>/dev/null || warn "ARM64 cross-compiler not in repos — trying yay"

    if command -v yay &>/dev/null; then
        log "Installing AUR packages via yay..."
        yay -S --needed --noconfirm --removemake \
            aarch64-linux-gnu-gcc aarch64-linux-gnu-binutils \
            2>/dev/null || warn "AUR ARM64 packages failed — skipping"
    else
        warn "yay not found — skipping AUR packages"
        info "Install yay: https://github.com/Jguer/yay#installation"
    fi

    log "Installing uv (Python package manager)..."
    if ! command -v uv &>/dev/null; then
        curl -LsSf https://astral.sh/uv/install.sh | sh
        export PATH="$HOME_DIR/.local/bin:$PATH"
    fi
    log "  uv: $(uv --version 2>/dev/null || echo 'not found')"
}

# ── Fix specific package version mismatches ───────────────────────

fix_packages() {
    log "=== Fixing Package Mismatches (selective) ==="

    local need_fix=()

    if ! qemu-system-x86_64 --version &>/dev/null 2>&1; then
        local missing
        missing="$(ldd "$(which qemu-system-x86_64)" 2>&1 | grep "not found" | head -3 || true)"
        if echo "$missing" | grep -q "GLIBC"; then
            log "  glibc mismatch detected for QEMU"
            need_fix+=(glibc lib32-glibc)
        fi
    fi

    if [[ ${#need_fix[@]} -gt 0 ]]; then
        log "  Updating: ${need_fix[*]}"
        sudo pacman -S --noconfirm "${need_fix[@]}" 2>&1 | tail -5
    else
        log "  No package mismatches detected"
    fi

    log "Verifying key binaries..."
    for cmd in qemu-system-x86_64 qemu-system-aarch64 virsh gcc make shellcheck; do
        if command -v "$cmd" &>/dev/null; then
            info "[OK] $cmd"
        else
            warn "[MISSING] $cmd"
        fi
    done
}

# ── KVM + nested virtualization + IOMMU ──────────────────────────

setup_kvm() {
    log "=== KVM + Nested Virtualization ==="

    sudo systemctl enable --now libvirtd 2>/dev/null || true
    sudo usermod -aG kvm,libvirt "$CURRENT_USER" 2>/dev/null || true

    if grep -q "GenuineIntel" /proc/cpuinfo 2>/dev/null; then
        local nested_file="/sys/module/kvm_intel/parameters/nested"
        if [[ -f "$nested_file" ]]; then
            local val
            val="$(cat "$nested_file")"
            if [[ "$val" != "Y" && "$val" != "1" ]]; then
                sudo modprobe -r kvm_intel 2>/dev/null || true
                sudo modprobe kvm_intel nested=1
                echo "options kvm_intel nested=1" | sudo tee /etc/modprobe.d/kvm-nested.conf >/dev/null
                log "  Intel nested virt: ENABLED"
            else
                log "  Intel nested virt: already enabled"
            fi
        fi
    elif grep -q "AuthenticAMD" /proc/cpuinfo 2>/dev/null; then
        local nested_file="/sys/module/kvm_amd/parameters/nested"
        if [[ -f "$nested_file" ]]; then
            local val
            val="$(cat "$nested_file")"
            if [[ "$val" != "1" ]]; then
                sudo modprobe -r kvm_amd 2>/dev/null || true
                sudo modprobe kvm_amd nested=1
                echo "options kvm_amd nested=1" | sudo tee /etc/modprobe.d/kvm-nested.conf >/dev/null
                log "  AMD nested virt: ENABLED"
            else
                log "  AMD nested virt: already enabled"
            fi
        fi
    fi

    log "=== IOMMU / GPU Passthrough ==="
    if dmesg 2>/dev/null | grep -qi "IOMMU enabled\|DMAR.*IOMMU\|AMD-Vi"; then
        log "  IOMMU: ACTIVE"
    else
        warn "IOMMU not detected — GPU passthrough needs kernel cmdline:"
        if grep -q "GenuineIntel" /proc/cpuinfo 2>/dev/null; then
            info "  intel_iommu=on iommu=pt"
        else
            info "  amd_iommu=on iommu=pt"
        fi
    fi

    sudo modprobe vfio-pci 2>/dev/null || true
    if ! grep -q "vfio-pci" /etc/modules-load.d/*.conf 2>/dev/null; then
        echo "vfio-pci" | sudo tee /etc/modules-load.d/vfio-pci.conf >/dev/null
    fi
}

# ── SSH server ───────────────────────────────────────────────────

setup_ssh() {
    log "=== SSH Server ==="
    sudo systemctl enable --now sshd
    if [[ ! -f "$HOME_DIR/.ssh/id_ed25519" ]]; then
        ssh-keygen -t ed25519 -f "$HOME_DIR/.ssh/id_ed25519" -N "" -C "qubes-kvm-test"
    fi
    local ip
    ip="$(ip -4 addr show scope global | grep -oP 'inet \K[\d.]+' | head -1 || echo 'unknown')"
    log "  SSH: running on $ip:22"
}

# ── Agent service (uses uv for Python) ───────────────────────────

setup_agent() {
    log "=== Agent Service (using uv) ==="

    if [[ ! -f "$AGENT_DIR/agent.py" ]]; then
        err "Agent not found at $AGENT_DIR/agent.py"
        return 1
    fi

    log "  Creating venv with uv..."
    if command -v uv &>/dev/null; then
        uv venv "$VENV_DIR" 2>/dev/null || python -m venv "$VENV_DIR"
        log "  Installing agent dependencies with uv..."
        uv pip install --python "$VENV_DIR/bin/python" \
            -r "$AGENT_DIR/requirements.txt" 2>&1 | tail -5
    else
        python -m venv "$VENV_DIR"
        "$VENV_DIR/bin/pip" install -q -r "$AGENT_DIR/requirements.txt" 2>&1 | tail -5
    fi

    log "  Installing systemd service..."
    local svc_content
    svc_content="$(cat << SVCEOF
[Unit]
Description=Qubes KVM Test Agent
After=network-online.target libvirtd.service
Wants=network-online.target

[Service]
Type=simple
User=${CURRENT_USER}
Group=${CURRENT_USER}
WorkingDirectory=${SCRIPT_DIR}
ExecStart=${VENV_DIR}/bin/python -m uvicorn agent:app --host 0.0.0.0 --port 8420 --log-level info --app-dir ${AGENT_DIR}
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
Environment=HOME=${HOME_DIR}
Environment=PATH=${VENV_DIR}/bin:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=multi-user.target
SVCEOF
)"
    echo "$svc_content" | sudo tee /etc/systemd/system/qubes-kvm-agent.service >/dev/null
    sudo systemctl daemon-reload
    sudo systemctl enable qubes-kvm-agent
    sudo systemctl restart qubes-kvm-agent

    local ip
    ip="$(ip -4 addr show scope global | grep -oP 'inet \K[\d.]+' | head -1 || echo 'localhost')"
    log "  Agent: http://$ip:8420"
    log "  Docs:  http://$ip:8420/docs"
}

# ── Readiness check ──────────────────────────────────────────────

run_check() {
    log "=== System Readiness Check ==="
    echo ""

    local pass=0 fail=0

    check_item() {
        if eval "$2" 2>/dev/null; then
            printf "  [PASS] %s\n" "$1"
            pass=$((pass + 1))
        else
            printf "  [FAIL] %s\n" "$1"
            fail=$((fail + 1))
        fi
    }

    check_item "/dev/kvm present" "test -e /dev/kvm"
    check_item "QEMU x86 installed" "command -v qemu-system-x86_64"
    check_item "QEMU x86 runs" "qemu-system-x86_64 --version >/dev/null 2>&1"
    check_item "QEMU ARM64 installed" "command -v qemu-system-aarch64"
    check_item "libvirtd running" "systemctl is-active libvirtd"
    check_item "sshd running" "systemctl is-active sshd"
    check_item "podman available" "command -v podman"
    check_item "gcc available" "command -v gcc"
    check_item "rust available" "command -v cargo"
    check_item "Python 3 available" "command -v python3"
    check_item "uv available" "command -v uv"
    check_item "ShellCheck available" "command -v shellcheck"
    check_item "Nested virt enabled" "cat /sys/module/kvm_intel/parameters/nested 2>/dev/null | grep -q Y || cat /sys/module/kvm_amd/parameters/nested 2>/dev/null | grep -q 1"
    check_item "VFIO module loaded" "lsmod | grep -q vfio"
    check_item "Agent service running" "systemctl is-active qubes-kvm-agent 2>/dev/null"
    check_item "Agent API responding" "curl -sf http://localhost:8420/health"

    echo ""
    log "Results: $pass passed, $fail failed"
    [[ $fail -eq 0 ]] && log "System is fully ready." || warn "Some checks failed."
    return "$fail"
}

# ── Main ─────────────────────────────────────────────────────────

main() {
    log "============================================"
    log " Qubes KVM Test — Machine Setup"
    log "============================================"

    case "${1:-full}" in
        --check|check)    run_check ;;
        --deps|deps)      install_deps ;;
        --kvm|kvm)        setup_kvm ;;
        --agent|agent)    setup_agent ;;
        --ssh|ssh)        setup_ssh ;;
        --fix-glibc|fix)  fix_packages ;;
        full|--full|"")
            check_hardware
            install_deps
            fix_packages
            setup_kvm
            setup_ssh
            setup_agent
            log ""
            log "=== Setup Complete ==="
            log "Log out and back in for group changes (kvm, libvirt)"
            run_check || true
            ;;
        *)
            echo "Usage: $(basename "$0") [full|check|deps|kvm|agent|ssh|fix]"
            ;;
    esac
}

main "$@"
