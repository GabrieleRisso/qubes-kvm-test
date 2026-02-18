#!/bin/bash
# launch-qubes-vm.sh — Direct QEMU launch of Qubes-on-KVM VM
#
# Uses KVM with virtio-serial QubesDB channel and bridge networking.
# Xen CPUID detection is exposed via a guest-side shim.
# Auto-detects host resources and reserves 2 cores + 2GB for the host.
#
# Usage:
#   bash scripts/launch-qubes-vm.sh         # Boot VM in background
#   bash scripts/launch-qubes-vm.sh stop    # Stop VM
#   bash scripts/launch-qubes-vm.sh status  # Check if running
#   bash scripts/launch-qubes-vm.sh ssh     # SSH into guest
#   bash scripts/launch-qubes-vm.sh verify  # Verify Qubes infra in guest
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VM_IMAGES="$PROJECT_DIR/vm-images"

VM_NAME="${VM_NAME:-qubes-kvm-node1}"
RESERVE_CORES="${RESERVE_CORES:-2}"
RESERVE_MEM_MB="${RESERVE_MEM_MB:-2048}"

HOST_CORES="$(nproc)"
HOST_MEM_MB="$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)"
VM_CPUS="${VM_CPUS:-$(( HOST_CORES - RESERVE_CORES ))}"
VM_MEM="${VM_MEM:-$(( HOST_MEM_MB - RESERVE_MEM_MB ))}"
(( VM_CPUS < 1 )) && VM_CPUS=1
(( VM_MEM < 1024 )) && VM_MEM=1024

BRIDGE="${BRIDGE:-virbr0}"
MONITOR_SOCK="/tmp/${VM_NAME}-monitor.sock"
SERIAL_SOCK="/tmp/${VM_NAME}-serial.sock"
QUBESDB_SOCK="/tmp/${VM_NAME}-qubesdb.sock"
PIDFILE="/tmp/${VM_NAME}.pid"

CLOUD_IMAGE="$VM_IMAGES/Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2"
VM_DISK="$VM_IMAGES/${VM_NAME}.qcow2"
CI_ISO="$VM_IMAGES/cloud-init-${VM_NAME}.iso"

log()  { echo "[launch] $*"; }
die()  { echo "[launch] ERROR: $*" >&2; exit 1; }

create_cloud_init() {
    local ci_dir="$VM_IMAGES/cloud-init-${VM_NAME}"
    mkdir -p "$ci_dir"

    cat > "$ci_dir/meta-data" << EOF
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
EOF

    cat > "$ci_dir/user-data" << 'EOF'
#cloud-config
users:
  - name: user
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: qubes
    ssh_authorized_keys: []
  - name: root
    lock_passwd: false
    plain_text_passwd: qubes

ssh_pwauth: true
disable_root: false

package_update: true
packages:
  - python3
  - python3-pip
  - qemu-guest-agent
  - pciutils
  - lshw
  - dmidecode
  - cpuid
  - socat

runcmd:
  - systemctl enable --now qemu-guest-agent || true
  - echo "Qubes-on-KVM guest booted successfully" > /etc/motd
  - |
    cat > /usr/local/bin/check-xen-cpuid.sh << 'SCRIPT'
    #!/bin/bash
    echo "=== Xen CPUID Detection ==="
    if command -v cpuid &>/dev/null; then
        cpuid -1 2>/dev/null | grep -i xen && echo "Xen CPUID: DETECTED" || echo "Xen CPUID: not found via cpuid"
    fi
    if [ -f /sys/hypervisor/type ]; then
        echo "Hypervisor type: $(cat /sys/hypervisor/type)"
    else
        echo "No /sys/hypervisor/type (expected in Xen PV, not HVM)"
    fi
    if dmesg 2>/dev/null | grep -i "xen\|hypervisor" | head -5; then
        echo "Xen references found in dmesg"
    fi
    if [ -d /proc/xen ]; then
        echo "/proc/xen: exists"
        ls /proc/xen/ 2>/dev/null
    fi
    lscpu 2>/dev/null | grep -i "hypervisor\|virtual"
    echo "=== Done ==="
    SCRIPT
    chmod +x /usr/local/bin/check-xen-cpuid.sh

write_files:
  - path: /etc/qubes-rpc/qubes.VMShell
    content: |
      #!/bin/bash
      exec /bin/bash
    permissions: '0755'
EOF

    genisoimage -output "$CI_ISO" -volid cidata -joliet -rock \
        "$ci_dir/user-data" "$ci_dir/meta-data" 2>/dev/null
    log "Cloud-init ISO: $CI_ISO"
}

create_disk() {
    if [[ -f "$VM_DISK" ]]; then
        log "Disk exists: $VM_DISK"
        return 0
    fi
    [[ -f "$CLOUD_IMAGE" ]] || die "Cloud image not found: $CLOUD_IMAGE"
    qemu-img create -f qcow2 -b "$CLOUD_IMAGE" -F qcow2 "$VM_DISK" 20G
    log "Disk: $VM_DISK"
}

cmd_launch() {
    if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        log "VM already running (PID $(cat "$PIDFILE"))"
        return 0
    fi

    [[ -e /dev/kvm ]] || die "/dev/kvm not found"

    create_disk
    create_cloud_init

    rm -f "$MONITOR_SOCK" "$SERIAL_SOCK" "$QUBESDB_SOCK"

    log "Starting Qubes-on-KVM VM: $VM_NAME"
    log "  Host: ${HOST_CORES} cores, ${HOST_MEM_MB}MB total"
    log "  VM:   ${VM_CPUS} cores, ${VM_MEM}MB RAM (reserved ${RESERVE_CORES} cores / ${RESERVE_MEM_MB}MB for host)"
    log "  Bridge: $BRIDGE"

    local run_as_sudo=""
    if [[ "$(id -u)" -ne 0 ]]; then
        run_as_sudo="sudo"
    fi

    $run_as_sudo qemu-system-x86_64 \
        -name "$VM_NAME" \
        -accel kvm \
        -cpu host \
        -m "$VM_MEM" \
        -smp "$VM_CPUS" \
        -machine q35 \
        -drive file="$VM_DISK",format=qcow2,if=virtio \
        -drive file="$CI_ISO",format=raw,if=none,id=cidata,readonly=on \
        -device ide-cd,drive=cidata \
        -netdev bridge,id=net0,br="$BRIDGE" \
        -device virtio-net-pci,netdev=net0 \
        -chardev socket,id=qubesdb,path="$QUBESDB_SOCK",server=on,wait=off \
        -device virtio-serial-pci \
        -device virtserialport,chardev=qubesdb,name=org.qubes-os.qubesdb \
        -device virtio-rng-pci \
        -monitor unix:"$MONITOR_SOCK",server,nowait \
        -serial unix:"$SERIAL_SOCK",server,nowait \
        -display none \
        -daemonize \
        -pidfile "$PIDFILE" \
        2>&1

    if [[ -f "$PIDFILE" ]]; then
        local vm_pid
        vm_pid="$(cat "$PIDFILE")"
        log ""
        log "VM started (PID $vm_pid)"
        log ""
        log "Waiting for DHCP lease..."
        local vm_ip="" tries=0
        while [[ -z "$vm_ip" ]] && (( tries < 30 )); do
            sleep 2
            vm_ip="$(sudo virsh net-dhcp-leases default 2>/dev/null | grep "$VM_NAME" | awk '{print $5}' | cut -d/ -f1 || true)"
            tries=$((tries + 1))
        done

        if [[ -n "$vm_ip" ]]; then
            log "VM IP: $vm_ip"
            log ""
            log "Access:"
            log "  SSH:     sshpass -p qubes ssh user@$vm_ip"
            log "  Console: sudo socat - UNIX-CONNECT:$SERIAL_SOCK"
            log "  Monitor: sudo socat - UNIX-CONNECT:$MONITOR_SOCK"
            log "  QubesDB: $QUBESDB_SOCK"
        else
            log "No DHCP lease yet. Check: sudo virsh net-dhcp-leases default"
            log "  Monitor: sudo socat - UNIX-CONNECT:$MONITOR_SOCK"
            log "  QubesDB: $QUBESDB_SOCK"
        fi
        log ""
        log "Verify: $0 verify"
    else
        die "VM failed to start"
    fi
}

get_vm_ip() {
    sudo virsh net-dhcp-leases default 2>/dev/null \
        | grep "$VM_NAME" | awk '{print $5}' | cut -d/ -f1 || true
}

cmd_stop() {
    if [[ ! -f "$PIDFILE" ]]; then
        log "No PID file. VM may not be running."
        return 0
    fi
    local pid
    pid="$(cat "$PIDFILE")"
    if kill -0 "$pid" 2>/dev/null; then
        log "Sending ACPI shutdown..."
        echo "system_powerdown" | sudo socat - UNIX-CONNECT:"$MONITOR_SOCK" 2>/dev/null || true
        local i=0
        while [[ $i -lt 15 ]] && kill -0 "$pid" 2>/dev/null; do
            sleep 1; i=$((i+1))
        done
        if kill -0 "$pid" 2>/dev/null; then
            log "Force killing..."
            sudo kill "$pid" 2>/dev/null || true
        fi
    fi
    sudo rm -f "$PIDFILE" "$MONITOR_SOCK" "$SERIAL_SOCK" "$QUBESDB_SOCK"
    log "VM stopped."
}

cmd_status() {
    if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        local vm_ip
        vm_ip="$(get_vm_ip)"
        log "VM running (PID $(cat "$PIDFILE"))"
        [[ -n "$vm_ip" ]] && log "  IP:      $vm_ip"
        log "  QubesDB: $QUBESDB_SOCK"
        [[ -S "$QUBESDB_SOCK" ]] && log "  QubesDB socket: active"
    else
        log "VM not running."
    fi
}

cmd_ssh() {
    local vm_ip
    vm_ip="$(get_vm_ip)"
    [[ -z "$vm_ip" ]] && die "Cannot determine VM IP. Is it running?"
    sshpass -p qubes ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 "user@$vm_ip"
}

cmd_verify() {
    local vm_ip
    vm_ip="$(get_vm_ip)"
    [[ -z "$vm_ip" ]] && die "Cannot determine VM IP. Is it running?"
    log "Verifying Qubes-on-KVM infrastructure in guest ($vm_ip)..."
    echo ""
    sshpass -p qubes ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 "user@$vm_ip" << 'REMOTEOF'
echo "=== Qubes-on-KVM Infrastructure Verification ==="
echo ""

echo "--- System ---"
hostname; uname -r; nproc; free -h | head -2

echo ""
echo "--- Hypervisor ---"
lscpu 2>/dev/null | grep -iE "hypervisor|vendor|virtual|model name"

echo ""
echo "--- QubesDB Channel ---"
if [ -e /dev/virtio-ports/org.qubes-os.qubesdb ]; then
    echo "  PASS: /dev/virtio-ports/org.qubes-os.qubesdb exists"
    ls -la /dev/virtio-ports/org.qubes-os.qubesdb
else
    echo "  FAIL: QubesDB virtio-serial port not found"
fi

echo ""
echo "--- Qubes RPC ---"
if [ -f /etc/qubes-rpc/qubes.VMShell ]; then
    echo "  PASS: qubes.VMShell RPC handler installed"
else
    echo "  MISSING: /etc/qubes-rpc/qubes.VMShell"
fi

echo ""
echo "--- Network ---"
ip -4 addr show scope global | grep -oP 'inet \K[\d./]+'

echo ""
echo "--- dmesg: hypervisor ---"
sudo dmesg 2>/dev/null | grep -iE "xen|hypervisor|paravirt|kvm" | head -10 || echo "  (no access)"

echo ""
echo "--- GPU / PCI ---"
lspci 2>/dev/null | grep -iE "vga|3d|display" || echo "  No GPU devices"

echo ""
echo "=== Verification Complete ==="
REMOTEOF
}

cmd_console() {
    [[ -S "$SERIAL_SOCK" ]] || die "Serial socket not found: $SERIAL_SOCK"
    log "Connecting serial console (Ctrl+C then kill socat to exit)..."
    socat -,raw,echo=0 UNIX-CONNECT:"$SERIAL_SOCK"
}

case "${1:-launch}" in
    launch|start|"") cmd_launch ;;
    stop)             cmd_stop ;;
    status)           cmd_status ;;
    ssh)              cmd_ssh ;;
    verify)           cmd_verify ;;
    console)          cmd_console ;;
    ip)               get_vm_ip ;;
    *)
        echo "Usage: $(basename "$0") [launch|stop|status|ssh|verify|console|ip]"
        echo ""
        echo "Env vars:"
        echo "  VM_NAME=$VM_NAME  VM_MEM=$VM_MEM  VM_CPUS=$VM_CPUS"
        echo "  RESERVE_CORES=$RESERVE_CORES  RESERVE_MEM_MB=$RESERVE_MEM_MB"
        echo "  BRIDGE=$BRIDGE"
        ;;
esac
