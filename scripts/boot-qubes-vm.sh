#!/bin/bash
# boot-qubes-vm.sh — Create and boot a Qubes-on-KVM virtual machine
#
# This script creates a VM that runs under QEMU's Xen HVM emulation,
# making the guest OS believe it's running under the Xen hypervisor
# (as in real Qubes OS). It sets up:
#   - QEMU Xen emulation (xen-version=0x40013)
#   - Cloud-init for automatic guest provisioning
#   - QubesDB virtio-serial channel
#   - Networking via libvirt default bridge
#
# Usage:
#   bash scripts/boot-qubes-vm.sh create    # Create + start VM
#   bash scripts/boot-qubes-vm.sh start     # Start existing VM
#   bash scripts/boot-qubes-vm.sh stop      # Graceful shutdown
#   bash scripts/boot-qubes-vm.sh destroy   # Force kill
#   bash scripts/boot-qubes-vm.sh status    # Show VM info
#   bash scripts/boot-qubes-vm.sh ssh       # SSH into VM
#   bash scripts/boot-qubes-vm.sh verify    # Check Xen CPUID inside guest
#   bash scripts/boot-qubes-vm.sh console   # Serial console
#   bash scripts/boot-qubes-vm.sh delete    # Remove VM entirely
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VM_IMAGES="$PROJECT_DIR/vm-images"

VM_NAME="${VM_NAME:-qubes-kvm-node1}"
VM_MEM="${VM_MEM:-4096}"
VM_CPUS="${VM_CPUS:-2}"
VM_DISK_SIZE="${VM_DISK_SIZE:-20G}"
VM_SSH_PORT="${VM_SSH_PORT:-2222}"
CLOUD_IMAGE="${CLOUD_IMAGE:-$VM_IMAGES/Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2}"

OVMF_CODE=""
for f in /usr/share/edk2/x64/OVMF_CODE.4m.fd \
         /usr/share/edk2/ovmf/OVMF_CODE.fd \
         /usr/share/OVMF/OVMF_CODE.fd; do
    [[ -f "$f" ]] && OVMF_CODE="$f" && break
done

OVMF_VARS_TEMPLATE=""
for f in /usr/share/edk2/x64/OVMF_VARS.4m.fd \
         /usr/share/edk2/ovmf/OVMF_VARS.fd \
         /usr/share/OVMF/OVMF_VARS.fd; do
    [[ -f "$f" ]] && OVMF_VARS_TEMPLATE="$f" && break
done

XEN_VERSION="0x40013"

log()  { echo "[boot-vm] $*"; }
die()  { echo "[boot-vm] ERROR: $*" >&2; exit 1; }

# ── Create cloud-init ISO ────────────────────────────────────────

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

runcmd:
  - systemctl enable --now qemu-guest-agent
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

    if command -v genisoimage &>/dev/null; then
        genisoimage -output "$VM_IMAGES/cloud-init-${VM_NAME}.iso" \
            -volid cidata -joliet -rock \
            "$ci_dir/user-data" "$ci_dir/meta-data" 2>/dev/null
    elif command -v mkisofs &>/dev/null; then
        mkisofs -output "$VM_IMAGES/cloud-init-${VM_NAME}.iso" \
            -volid cidata -joliet -rock \
            "$ci_dir/user-data" "$ci_dir/meta-data" 2>/dev/null
    elif command -v xorriso &>/dev/null; then
        xorriso -as mkisofs -output "$VM_IMAGES/cloud-init-${VM_NAME}.iso" \
            -volid cidata -joliet -rock \
            "$ci_dir/user-data" "$ci_dir/meta-data" 2>/dev/null
    else
        die "No ISO creation tool found. Install: sudo pacman -S cdrtools"
    fi

    log "Cloud-init ISO: $VM_IMAGES/cloud-init-${VM_NAME}.iso"
}

# ── Create VM disk ───────────────────────────────────────────────

create_disk() {
    local disk="$VM_IMAGES/${VM_NAME}.qcow2"

    if [[ -f "$disk" ]]; then
        log "Disk already exists: $disk"
        return 0
    fi

    if [[ ! -f "$CLOUD_IMAGE" ]]; then
        die "Cloud image not found: $CLOUD_IMAGE"
    fi

    log "Creating VM disk (backing: $(basename "$CLOUD_IMAGE"), size: $VM_DISK_SIZE)..."
    qemu-img create -f qcow2 -b "$CLOUD_IMAGE" -F qcow2 "$disk" "$VM_DISK_SIZE"
    log "Disk: $disk"
}

# ── Generate libvirt XML with Xen emulation ──────────────────────

generate_xml() {
    local disk="$VM_IMAGES/${VM_NAME}.qcow2"
    local ci_iso="$VM_IMAGES/cloud-init-${VM_NAME}.iso"
    local ovmf_vars="$VM_IMAGES/${VM_NAME}-OVMF_VARS.fd"

    if [[ -n "$OVMF_VARS_TEMPLATE" ]] && [[ ! -f "$ovmf_vars" ]]; then
        cp "$OVMF_VARS_TEMPLATE" "$ovmf_vars"
    fi

    local loader_xml=""
    local nvram_xml=""
    if [[ -n "$OVMF_CODE" ]]; then
        loader_xml="<loader readonly=\"yes\" type=\"pflash\">$OVMF_CODE</loader>"
        if [[ -f "$ovmf_vars" ]]; then
            nvram_xml="<nvram>$ovmf_vars</nvram>"
        fi
    fi

    local ci_disk=""
    if [[ -f "$ci_iso" ]]; then
        ci_disk="<disk type=\"file\" device=\"cdrom\">
            <driver name=\"qemu\" type=\"raw\"/>
            <source file=\"$ci_iso\"/>
            <target dev=\"sda\" bus=\"sata\"/>
            <readonly/>
        </disk>"
    fi

    cat << XMLEOF
<domain type="kvm" xmlns:qemu="http://libvirt.org/schemas/domain/qemu/1.0">
    <name>$VM_NAME</name>
    <memory unit="MiB">$VM_MEM</memory>
    <currentMemory unit="MiB">$VM_MEM</currentMemory>
    <vcpu placement="static">$VM_CPUS</vcpu>
    <cpu mode="host-passthrough"/>
    <os>
        <type arch="x86_64" machine="q35">hvm</type>
        $loader_xml
        $nvram_xml
        <boot dev="hd"/>
    </os>
    <features>
        <pae/>
        <acpi/>
        <apic/>
        <kvm>
            <hidden state="on"/>
        </kvm>
    </features>
    <clock offset="utc">
        <timer name="rtc" tickpolicy="catchup"/>
        <timer name="pit" tickpolicy="delay"/>
        <timer name="hpet" present="no"/>
    </clock>
    <on_poweroff>destroy</on_poweroff>
    <on_reboot>restart</on_reboot>
    <on_crash>destroy</on_crash>
    <devices>
        <emulator>/usr/bin/qemu-system-x86_64</emulator>
        <disk type="file" device="disk">
            <driver name="qemu" type="qcow2" cache="none"/>
            <source file="$disk"/>
            <target dev="vda" bus="virtio"/>
        </disk>
        $ci_disk
        <interface type="network">
            <source network="default"/>
            <model type="virtio"/>
        </interface>
        <console type="pty">
            <target type="serial" port="0"/>
        </console>
        <serial type="pty">
            <target port="0"/>
        </serial>
        <channel type="unix">
            <target type="virtio" name="org.qemu.guest_agent.0"/>
        </channel>
        <channel type="unix">
            <source mode="bind" path="/var/run/qubes/qubesdb.${VM_NAME}.sock"/>
            <target type="virtio" name="org.qubes-os.qubesdb"/>
        </channel>
        <vsock model="virtio">
            <cid auto="yes"/>
        </vsock>
        <memballoon model="virtio">
            <stats period="5"/>
        </memballoon>
        <rng model="virtio">
            <backend model="random">/dev/urandom</backend>
        </rng>
        <input type="tablet" bus="virtio"/>
        <input type="keyboard" bus="virtio"/>
    </devices>
    <qemu:commandline>
        <qemu:arg value="-accel"/>
        <qemu:arg value="kvm,xen-version=$XEN_VERSION,kernel-irqchip=split"/>
        <qemu:arg value="-cpu"/>
        <qemu:arg value="host,+xen-vapic"/>
    </qemu:commandline>
    <seclabel type="dynamic" model="dac" relabel="yes"/>
</domain>
XMLEOF
}

# ── Commands ─────────────────────────────────────────────────────

cmd_create() {
    log "Creating Qubes-on-KVM VM: $VM_NAME"
    log "  Memory: ${VM_MEM}MB, CPUs: $VM_CPUS, Disk: $VM_DISK_SIZE"
    log "  Xen emulation: version $XEN_VERSION"

    sudo mkdir -p /var/run/qubes

    create_disk
    create_cloud_init

    if sudo virsh dominfo "$VM_NAME" &>/dev/null; then
        log "Domain already exists, removing..."
        sudo virsh destroy "$VM_NAME" 2>/dev/null || true
        sudo virsh undefine "$VM_NAME" --nvram 2>/dev/null || sudo virsh undefine "$VM_NAME" 2>/dev/null || true
    fi

    log "Defining domain via libvirt..."
    local xml
    xml="$(generate_xml)"
    echo "$xml" | sudo virsh define /dev/stdin

    log "Starting domain..."
    sudo virsh start "$VM_NAME"

    log ""
    log "VM '$VM_NAME' is booting with Xen-on-KVM emulation."
    log ""
    log "Wait ~60s for cloud-init, then:"
    log "  $0 ssh        # SSH into VM (user/qubes)"
    log "  $0 verify     # Check Xen CPUID detection"
    log "  $0 console    # Serial console (Ctrl+] to exit)"
    log "  $0 status     # VM info"
}

cmd_start() {
    if ! sudo virsh dominfo "$VM_NAME" &>/dev/null; then
        die "VM '$VM_NAME' not defined. Run: $0 create"
    fi
    sudo virsh start "$VM_NAME"
    log "VM '$VM_NAME' started."
}

cmd_stop() {
    log "Shutting down '$VM_NAME'..."
    sudo virsh shutdown "$VM_NAME"
    local i=0
    while [[ $i -lt 30 ]]; do
        local state
        state="$(sudo virsh domstate "$VM_NAME" 2>/dev/null || echo "shut off")"
        [[ "$state" == "shut off" ]] && { log "VM stopped."; return 0; }
        sleep 1
        i=$((i + 1))
    done
    log "Timeout. Use: $0 destroy"
}

cmd_destroy() {
    sudo virsh destroy "$VM_NAME" 2>/dev/null || log "VM already stopped."
}

cmd_delete() {
    cmd_destroy 2>/dev/null || true
    sudo virsh undefine "$VM_NAME" --nvram 2>/dev/null || sudo virsh undefine "$VM_NAME" 2>/dev/null || true
    rm -f "$VM_IMAGES/${VM_NAME}.qcow2"
    rm -f "$VM_IMAGES/${VM_NAME}-OVMF_VARS.fd"
    rm -f "$VM_IMAGES/cloud-init-${VM_NAME}.iso"
    rm -rf "$VM_IMAGES/cloud-init-${VM_NAME}"
    log "VM '$VM_NAME' fully removed."
}

cmd_status() {
    if ! sudo virsh dominfo "$VM_NAME" &>/dev/null; then
        log "VM '$VM_NAME' is not defined."
        return 1
    fi

    echo "=== VM: $VM_NAME ==="
    sudo virsh dominfo "$VM_NAME"
    echo ""

    local xml
    xml="$(sudo virsh dumpxml "$VM_NAME" 2>/dev/null || true)"
    if echo "$xml" | grep -q "xen-version"; then
        echo "Xen HVM emulation: ACTIVE"
        echo "  $(echo "$xml" | grep -oP 'xen-version=\S+' | head -1)"
    else
        echo "Xen HVM emulation: NOT configured"
    fi

    echo ""
    local ip
    ip="$(sudo virsh domifaddr "$VM_NAME" 2>/dev/null | grep -oP '[\d.]+/\d+' | cut -d/ -f1 | head -1 || true)"
    if [[ -n "$ip" ]]; then
        echo "IP address: $ip"
        echo "SSH: ssh user@$ip (password: qubes)"
    else
        echo "IP address: (not yet assigned — VM may still be booting)"
    fi
}

cmd_ssh() {
    local ip
    ip="$(sudo virsh domifaddr "$VM_NAME" 2>/dev/null | grep -oP '[\d.]+/\d+' | cut -d/ -f1 | head -1 || true)"
    if [[ -z "$ip" ]]; then
        die "Cannot determine VM IP. Is it running? Try: $0 status"
    fi
    log "Connecting to $VM_NAME at $ip..."
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "user@$ip"
}

cmd_verify() {
    local ip
    ip="$(sudo virsh domifaddr "$VM_NAME" 2>/dev/null | grep -oP '[\d.]+/\d+' | cut -d/ -f1 | head -1 || true)"
    if [[ -z "$ip" ]]; then
        die "Cannot determine VM IP. Is it running?"
    fi

    log "Verifying Xen CPUID inside guest ($ip)..."
    echo ""

    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 "user@$ip" << 'VERIFY_EOF'
echo "=== Xen CPUID and Hypervisor Detection ==="
echo ""

echo "--- CPUID leaf 0x40000000 (hypervisor signature) ---"
if command -v cpuid &>/dev/null; then
    cpuid -1 -l 0x40000000 2>/dev/null | head -10
else
    echo "(cpuid tool not installed)"
fi

echo ""
echo "--- /sys/hypervisor ---"
if [ -d /sys/hypervisor ]; then
    for f in /sys/hypervisor/*; do
        [ -f "$f" ] && echo "  $(basename $f): $(cat $f 2>/dev/null)"
    done
else
    echo "  /sys/hypervisor: not present"
fi

echo ""
echo "--- dmesg hypervisor references ---"
dmesg 2>/dev/null | grep -iE "xen|hypervisor|kvm|paravirt" | head -10

echo ""
echo "--- lscpu virtualization ---"
lscpu 2>/dev/null | grep -iE "hypervisor|virtual|vendor"

echo ""
echo "--- /proc/cpuinfo flags (xen-related) ---"
grep -oE 'hypervisor' /proc/cpuinfo | head -1 || echo "  no hypervisor flag"

echo ""
echo "--- Xen-specific devices ---"
ls -la /dev/xen* 2>/dev/null || echo "  no /dev/xen* devices"
ls /proc/xen/ 2>/dev/null || echo "  no /proc/xen"

echo ""
echo "--- QubesDB virtio channel ---"
ls -la /dev/virtio-ports/ 2>/dev/null || echo "  no virtio-ports"
ls -la /dev/vport* 2>/dev/null || echo "  no vport devices"

echo ""
echo "=== Verification Complete ==="
VERIFY_EOF
}

cmd_console() {
    log "Connecting to serial console (Ctrl+] to exit)..."
    sudo virsh console "$VM_NAME"
}

# ── Main ─────────────────────────────────────────────────────────

main() {
    case "${1:-help}" in
        create)  cmd_create ;;
        start)   cmd_start ;;
        stop)    cmd_stop ;;
        destroy) cmd_destroy ;;
        delete)  cmd_delete ;;
        status)  cmd_status ;;
        ssh)     cmd_ssh ;;
        verify)  cmd_verify ;;
        console) cmd_console ;;
        *)
            echo "Usage: $(basename "$0") <command>"
            echo ""
            echo "  create   Create + boot Qubes-on-KVM VM"
            echo "  start    Start existing VM"
            echo "  stop     Graceful shutdown"
            echo "  destroy  Force kill"
            echo "  delete   Remove VM entirely"
            echo "  status   Show VM info + IP"
            echo "  ssh      SSH into guest"
            echo "  verify   Check Xen CPUID inside guest"
            echo "  console  Serial console"
            echo ""
            echo "Environment:"
            echo "  VM_NAME=$VM_NAME"
            echo "  VM_MEM=$VM_MEM  VM_CPUS=$VM_CPUS  VM_DISK_SIZE=$VM_DISK_SIZE"
            ;;
    esac
}

main "$@"
