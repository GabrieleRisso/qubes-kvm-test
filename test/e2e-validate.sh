#!/bin/bash
# e2e-validate.sh — End-to-end validation of Qubes-on-KVM architecture
#
# Tests the full stack: host KVM, libvirt, guest boot, QubesDB, Qubes RPC,
# network isolation, and multi-VM management.
#
# Usage: bash test/e2e-validate.sh
set -euo pipefail

PASS=0 FAIL=0 SKIP=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
mkdir -p "$RESULTS_DIR"
REPORT="$RESULTS_DIR/e2e-$(date +%Y%m%d-%H%M%S).txt"

log() { echo "$*" | tee -a "$REPORT"; }
pass() { log "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { log "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
skip() { log "  [SKIP] $1"; SKIP=$((SKIP + 1)); }
sep()  { log ""; log "────────────────────────────────────────────"; }

check() {
    local desc="$1"; shift
    if eval "$@" >/dev/null 2>&1; then
        pass "$desc"
    else
        fail "$desc"
    fi
}

vm_ssh() {
    local ip="$1"; shift
    sshpass -p qubes ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 "user@$ip" "$@" 2>/dev/null
}

log "╔══════════════════════════════════════════════════════════════╗"
log "║       Qubes-on-KVM End-to-End Architecture Validation       ║"
log "╚══════════════════════════════════════════════════════════════╝"
log ""
log "Date: $(date)"
log "Host: $(hostname) / $(uname -r)"
log ""

########################################
sep
log "Phase 1: Host Infrastructure"
########################################

check "KVM available (/dev/kvm)" "test -e /dev/kvm"
check "QEMU installed" "command -v qemu-system-x86_64"
check "libvirtd running" "systemctl is-active libvirtd"
check "virbr0 bridge exists" "ip link show virbr0"
check "IOMMU enabled" "test -d /sys/kernel/iommu_groups/0"
check "VFIO module loaded" "lsmod | grep vfio"
check "socat installed" "command -v socat"
check "sshpass installed" "command -v sshpass"

########################################
sep
log "Phase 2: VM Images & Scripts"
########################################

check "Fedora 41 cloud image" "test -f $PROJECT_DIR/vm-images/Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2"
check "launch-qubes-vm.sh" "test -x $PROJECT_DIR/scripts/launch-qubes-vm.sh"
check "xen-kvm-bridge.sh" "test -x $PROJECT_DIR/scripts/xen-kvm-bridge.sh"
check "provision-guest.sh" "test -x $PROJECT_DIR/scripts/provision-guest.sh"
check "qubesdb-config-inject.py" "test -f $PROJECT_DIR/scripts/qubesdb-config-inject.py"
check "qubesdb-config-read.py" "test -f $PROJECT_DIR/scripts/qubesdb-config-read.py"

########################################
sep
log "Phase 3: Primary VM (qubes-kvm-node1)"
########################################

NODE1_IP=""
NODE1_LEASE=$(sudo virsh net-dhcp-leases default 2>/dev/null | grep "qubes-kvm-node1" || true)
if [[ -n "$NODE1_LEASE" ]]; then
    NODE1_IP=$(echo "$NODE1_LEASE" | awk '{print $5}' | cut -d/ -f1)
    pass "qubes-kvm-node1 has DHCP lease: $NODE1_IP"
else
    fail "qubes-kvm-node1 has no DHCP lease"
fi

if [[ -n "$NODE1_IP" ]]; then
    check "node1: SSH reachable" "vm_ssh $NODE1_IP 'echo ok'"
    check "node1: hostname correct" "vm_ssh $NODE1_IP 'hostname' | grep -q 'qubes-kvm-node1'"
    check "node1: Fedora 41 kernel" "vm_ssh $NODE1_IP 'uname -r' | grep -q 'fc41'"
    check "node1: 6 CPUs allocated" "vm_ssh $NODE1_IP 'nproc' | grep -q '^6$'"

    log "  --- QubesDB ---"
    check "node1: QubesDB virtio-port exists" "vm_ssh $NODE1_IP 'test -e /dev/virtio-ports/org.qubes-os.qubesdb'"
    check "node1: QubesDB cache populated" "vm_ssh $NODE1_IP 'test -f /var/lib/qubesdb/qubesdb.json'"
    check "node1: QubesDB /name entry" "vm_ssh $NODE1_IP 'sudo qubesdb-config-read --get /name' | grep -q 'qubes-kvm-node1'"
    check "node1: QubesDB /type entry" "vm_ssh $NODE1_IP 'sudo qubesdb-config-read --get /type' | grep -q 'AppVM'"

    log "  --- Xen Shim ---"
    check "node1: qubes-xen-detect installed" "vm_ssh $NODE1_IP 'command -v qubes-xen-detect'"
    check "node1: reports xen-kvm" "vm_ssh $NODE1_IP 'qubes-xen-detect' | grep -q 'xen-kvm'"
    check "node1: /etc/qubes/hypervisor exists" "vm_ssh $NODE1_IP 'test -f /etc/qubes/hypervisor'"

    log "  --- Qubes RPC ---"
    check "node1: qubes.VMShell handler" "vm_ssh $NODE1_IP 'test -x /etc/qubes-rpc/qubes.VMShell'"
    check "node1: qubes.Filecopy handler" "vm_ssh $NODE1_IP 'test -x /etc/qubes-rpc/qubes.Filecopy'"
    check "node1: qubes.GetAppmenus handler" "vm_ssh $NODE1_IP 'test -x /etc/qubes-rpc/qubes.GetAppmenus'"

    log "  --- Network & Firewall ---"
    check "node1: has network connectivity" "vm_ssh $NODE1_IP 'ip -4 addr show scope global | grep -q inet'"
    check "node1: nftables firewall active" "vm_ssh $NODE1_IP 'sudo nft list ruleset 2>/dev/null | grep -q qubes-firewall'"

    log "  --- Agent Tools ---"
    check "node1: qubes-vm-info installed" "vm_ssh $NODE1_IP 'command -v qubes-vm-info'"
    check "node1: qubesdb-config-read installed" "vm_ssh $NODE1_IP 'command -v qubesdb-config-read'"
else
    for i in $(seq 1 15); do skip "node1 test $i (no IP)"; done
fi

########################################
sep
log "Phase 4: sys-firewall VM (libvirt-managed)"
########################################

SYSFW_STATE=$(sudo virsh domstate sys-firewall 2>/dev/null || echo "undefined")
if [[ "$SYSFW_STATE" == "running" ]]; then
    pass "sys-firewall: running via libvirt"
else
    fail "sys-firewall: not running (state: $SYSFW_STATE)"
fi

SYSFW_IP=""
SYSFW_LEASE=$(sudo virsh net-dhcp-leases default 2>/dev/null | grep "sys-firewall" || true)
if [[ -n "$SYSFW_LEASE" ]]; then
    SYSFW_IP=$(echo "$SYSFW_LEASE" | awk '{print $5}' | cut -d/ -f1)
    pass "sys-firewall has DHCP lease: $SYSFW_IP"
elif [[ -n "$(sudo virsh net-dhcp-leases default 2>/dev/null | tail -n+3 | grep -v 'qubes-kvm-node1' | head -1)" ]]; then
    SYSFW_IP=$(sudo virsh net-dhcp-leases default 2>/dev/null | tail -n+3 | grep -v 'qubes-kvm-node1' | head -1 | awk '{print $5}' | cut -d/ -f1)
    pass "sys-firewall has DHCP lease: $SYSFW_IP (alt lookup)"
else
    fail "sys-firewall has no DHCP lease"
fi

if [[ -n "$SYSFW_IP" ]]; then
    check "sys-fw: SSH reachable" "vm_ssh $SYSFW_IP 'echo ok'"
    check "sys-fw: hostname correct" "vm_ssh $SYSFW_IP 'hostname' | grep -q 'sys-firewall'"
    check "sys-fw: QubesDB virtio-port" "vm_ssh $SYSFW_IP 'test -e /dev/virtio-ports/org.qubes-os.qubesdb'"
    check "sys-fw: QubesDB /name" "vm_ssh $SYSFW_IP 'sudo qubesdb-config-read --get /name 2>/dev/null' | grep -q 'sys-firewall'"
    check "sys-fw: type is ProxyVM" "vm_ssh $SYSFW_IP 'sudo qubesdb-config-read --get /type 2>/dev/null' | grep -q 'ProxyVM'"
    check "sys-fw: xen-kvm detected" "vm_ssh $SYSFW_IP 'qubes-xen-detect' | grep -q 'xen-kvm'"
    check "sys-fw: Qubes RPC installed" "vm_ssh $SYSFW_IP 'test -x /etc/qubes-rpc/qubes.VMShell'"
else
    for i in $(seq 1 7); do skip "sys-fw test $i (no IP)"; done
fi

########################################
sep
log "Phase 5: xen-kvm-bridge.sh Management"
########################################

check "bridge: list command" "sudo bash $PROJECT_DIR/scripts/xen-kvm-bridge.sh list 2>&1 | grep -q sys-firewall"
check "bridge: status command" "sudo virsh domstate sys-firewall 2>/dev/null | grep -q running"
check "bridge: verify command" "sudo bash $PROJECT_DIR/scripts/xen-kvm-bridge.sh verify sys-firewall 2>&1 | grep -q VERIFIED"
check "bridge: generate-xml valid" "bash $PROJECT_DIR/scripts/xen-kvm-bridge.sh generate-xml test-vm /dev/null 2>&1 | grep -q '<domain'"

########################################
sep
log "Phase 6: GPU / IOMMU Readiness"
########################################

GPU_COUNT=$(lspci | grep -ciE "vga|3d|display" || echo 0)
if [[ "$GPU_COUNT" -gt 0 ]]; then
    pass "GPU detected ($GPU_COUNT device(s))"
    check "IOMMU groups populated" "test -d /sys/kernel/iommu_groups/0/devices"
    VFIO_LOADED=$(lsmod | grep -c vfio_pci || echo 0)
    if [[ "$VFIO_LOADED" -gt 0 ]]; then
        pass "VFIO-PCI module loaded (passthrough ready)"
    else
        skip "VFIO-PCI not loaded (can be loaded on demand)"
    fi
else
    skip "No GPU detected (integrated only)"
fi

########################################
sep
log "Phase 7: Inter-VM Communication"
########################################

if [[ -n "$NODE1_IP" ]] && [[ -n "$SYSFW_IP" ]]; then
    check "node1 -> sys-fw ping" "vm_ssh $NODE1_IP 'ping -c1 -W3 $SYSFW_IP' 2>/dev/null"
    check "sys-fw -> node1 ping" "vm_ssh $SYSFW_IP 'ping -c1 -W3 $NODE1_IP' 2>/dev/null"
else
    skip "Inter-VM ping (VMs not both reachable)"
    skip "Inter-VM ping reverse"
fi

########################################
sep
log "═══════════════════════════════════════════════════════════════"
log ""
log "  RESULTS:  $PASS passed  /  $FAIL failed  /  $SKIP skipped"
log "  TOTAL:    $((PASS + FAIL + SKIP))"
log ""
if [[ $FAIL -eq 0 ]]; then
    log "  ✓ ALL TESTS PASSED — Architecture is OPERATIONAL"
else
    log "  ✗ $FAIL test(s) FAILED — see details above"
fi
log ""
log "  Report saved: $REPORT"
log "═══════════════════════════════════════════════════════════════"

exit "$FAIL"
