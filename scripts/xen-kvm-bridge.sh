#!/bin/bash
# xen-kvm-bridge.sh — Bridge layer for managing KVM-Xen VMs via libvirt
#
# This script provides the glue between qubesd and libvirt for VMs that
# use QEMU's Xen HVM emulation. It can:
#   - Define/start/stop Xen-emulated VMs through libvirt
#   - Generate libvirt XML with the correct QEMU Xen emulation flags
#   - Verify that a running VM has Xen emulation active
#   - List all Xen-shim VMs and their status
#
# Usage:
#   xen-kvm-bridge.sh define  VM_NAME DISK [MEM_MB] [VCPUS]
#   xen-kvm-bridge.sh install VM_NAME DISK ISO [MEM_MB] [VCPUS]
#   xen-kvm-bridge.sh start   VM_NAME
#   xen-kvm-bridge.sh stop    VM_NAME
#   xen-kvm-bridge.sh destroy VM_NAME
#   xen-kvm-bridge.sh undefine VM_NAME
#   xen-kvm-bridge.sh status  VM_NAME
#   xen-kvm-bridge.sh list
#   xen-kvm-bridge.sh verify  VM_NAME
#   xen-kvm-bridge.sh console VM_NAME
#   xen-kvm-bridge.sh generate-xml VM_NAME DISK [MEM_MB] [VCPUS]
#   xen-kvm-bridge.sh gpu-define  VM_NAME DISK PCI_ADDR [MEM_MB] [VCPUS]
#   xen-kvm-bridge.sh gpu-list
set -euo pipefail

LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"
XEN_VERSION="0x40013"
VIRSH="virsh -c $LIBVIRT_URI"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[xen-kvm-bridge] $*"; }

generate_domain_xml() {
    local name="$1"
    local disk="$2"
    local mem="${3:-2048}"
    local vcpus="${4:-2}"
    local disk_abs
    disk_abs="$(realpath "$disk" 2>/dev/null || echo "$disk")"

    local disk_type="file"
    local disk_source_attr="file"
    local disk_driver_type="qcow2"
    if [[ "$disk_abs" == /dev/* ]]; then
        disk_type="block"
        disk_source_attr="dev"
        disk_driver_type="raw"
    elif file "$disk_abs" 2>/dev/null | grep -qi "raw\|data"; then
        disk_driver_type="raw"
    fi

    # OVMF detection
    local ovmf=""
    for f in /usr/share/edk2/ovmf/OVMF_CODE.fd \
             /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/edk2/xen/OVMF.fd; do
        [[ -f "$f" ]] && ovmf="$f" && break
    done

    local loader_xml=""
    if [[ -n "$ovmf" ]]; then
        loader_xml="<loader readonly=\"yes\" type=\"pflash\">$ovmf</loader>"
    fi

    cat << XMLEOF
<domain type="kvm" xmlns:qemu="http://libvirt.org/schemas/domain/qemu/1.0">
    <name>$name</name>
    <memory unit="MiB">$mem</memory>
    <currentMemory unit="MiB">$mem</currentMemory>
    <vcpu placement="static">$vcpus</vcpu>
    <cpu mode="host-passthrough"/>
    <os>
        <type arch="x86_64" machine="q35">hvm</type>
        $loader_xml
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
    <on_reboot>destroy</on_reboot>
    <on_crash>destroy</on_crash>
    <devices>
        <emulator>/usr/bin/qemu-system-x86_64</emulator>
        <disk type="$disk_type" device="disk">
            <driver name="qemu" type="$disk_driver_type" cache="none"/>
            <source ${disk_source_attr}="${disk_abs}"/>
            <target dev="vda" bus="virtio"/>
        </disk>
        <interface type="user">
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
            <source mode="bind" path="/var/run/qubes/qubesdb.${name}.sock"/>
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

generate_install_xml() {
    local name="$1"
    local disk="$2"
    local iso="$3"
    local mem="${4:-2048}"
    local vcpus="${5:-2}"
    local disk_abs iso_abs
    disk_abs="$(realpath "$disk" 2>/dev/null || echo "$disk")"
    iso_abs="$(realpath "$iso" 2>/dev/null || echo "$iso")"

    local disk_type="file"
    local disk_source_attr="file"
    local disk_driver_type="qcow2"
    if [[ "$disk_abs" == /dev/* ]]; then
        disk_type="block"
        disk_source_attr="dev"
        disk_driver_type="raw"
    elif file "$disk_abs" 2>/dev/null | grep -qi "raw\|data"; then
        disk_driver_type="raw"
    fi

    local ovmf=""
    for f in /usr/share/edk2/ovmf/OVMF_CODE.fd \
             /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/edk2/xen/OVMF.fd; do
        [[ -f "$f" ]] && ovmf="$f" && break
    done

    local loader_xml=""
    if [[ -n "$ovmf" ]]; then
        loader_xml="<loader readonly=\"yes\" type=\"pflash\">$ovmf</loader>"
    fi

    cat << XMLEOF
<domain type="kvm" xmlns:qemu="http://libvirt.org/schemas/domain/qemu/1.0">
    <name>$name</name>
    <memory unit="MiB">$mem</memory>
    <currentMemory unit="MiB">$mem</currentMemory>
    <vcpu placement="static">$vcpus</vcpu>
    <cpu mode="host-passthrough"/>
    <os>
        <type arch="x86_64" machine="q35">hvm</type>
        $loader_xml
        <boot dev="cdrom"/>
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
    <on_reboot>destroy</on_reboot>
    <on_crash>destroy</on_crash>
    <devices>
        <emulator>/usr/bin/qemu-system-x86_64</emulator>
        <disk type="$disk_type" device="disk">
            <driver name="qemu" type="$disk_driver_type" cache="none"/>
            <source ${disk_source_attr}="${disk_abs}"/>
            <target dev="vda" bus="virtio"/>
        </disk>
        <disk type="file" device="cdrom">
            <driver name="qemu" type="raw"/>
            <source file="${iso_abs}"/>
            <target dev="sda" bus="sata"/>
            <readonly/>
        </disk>
        <interface type="user">
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
            <source mode="bind" path="/var/run/qubes/qubesdb.${name}.sock"/>
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

cmd_install() {
    local name="${1:?Usage: $0 install VM_NAME DISK ISO [MEM_MB] [VCPUS]}"
    local disk="${2:?Usage: $0 install VM_NAME DISK ISO [MEM_MB] [VCPUS]}"
    local iso="${3:?Usage: $0 install VM_NAME DISK ISO [MEM_MB] [VCPUS]}"
    local mem="${4:-2048}"
    local vcpus="${5:-2}"

    [[ -e "$disk" ]] || die "Disk image not found: $disk"
    [[ -e "$iso" ]]  || die "ISO not found: $iso"

    if $VIRSH dominfo "$name" &>/dev/null; then
        info "Domain '$name' already defined. Undefining first..."
        $VIRSH destroy "$name" 2>/dev/null || true
        $VIRSH undefine "$name" --nvram 2>/dev/null || $VIRSH undefine "$name" 2>/dev/null || true
    fi

    info "Defining Xen-on-KVM install domain: $name (with CDROM)"
    local xml
    xml="$(generate_install_xml "$name" "$disk" "$iso" "$mem" "$vcpus")"
    echo "$xml" | $VIRSH define /dev/stdin

    info "Starting domain '$name' for installation..."
    $VIRSH start "$name"
    info "Domain '$name' started with CDROM. Connect with:"
    info "  $0 console $name"
    info "After install, undefine and redefine without CDROM:"
    info "  $0 undefine $name"
    info "  $0 define $name $disk $mem $vcpus"
}

cmd_console() {
    local name="${1:?Usage: $0 console VM_NAME}"
    if ! $VIRSH dominfo "$name" &>/dev/null; then
        die "Domain '$name' not defined."
    fi
    local state
    state=$($VIRSH domstate "$name" 2>/dev/null || echo "shut off")
    if [[ "$state" != "running" ]]; then
        die "Domain '$name' is not running (state: $state). Start it first."
    fi
    info "Connecting to serial console of '$name' (Ctrl+] to exit)..."
    $VIRSH console "$name"
}

cmd_define() {
    local name="${1:?Usage: $0 define VM_NAME DISK [MEM_MB] [VCPUS]}"
    local disk="${2:?Usage: $0 define VM_NAME DISK [MEM_MB] [VCPUS]}"
    local mem="${3:-2048}"
    local vcpus="${4:-2}"

    [[ -e "$disk" ]] || die "Disk image not found: $disk"

    if $VIRSH dominfo "$name" &>/dev/null; then
        die "Domain '$name' already exists. Undefine it first."
    fi

    info "Generating libvirt XML for Xen-on-KVM domain: $name"
    local xml
    xml="$(generate_domain_xml "$name" "$disk" "$mem" "$vcpus")"

    info "Defining domain via libvirt..."
    echo "$xml" | $VIRSH define /dev/stdin
    info "Domain '$name' defined. Start with: $0 start $name"
}

cmd_start() {
    local name="${1:?Usage: $0 start VM_NAME}"

    if ! $VIRSH dominfo "$name" &>/dev/null; then
        die "Domain '$name' not defined. Define it first."
    fi

    local state
    state=$($VIRSH domstate "$name" 2>/dev/null || true)
    if [[ "$state" == "running" ]]; then
        info "Domain '$name' is already running."
        return 0
    fi

    info "Starting Xen-on-KVM domain: $name"
    $VIRSH start "$name"
    info "Domain '$name' started."
}

cmd_stop() {
    local name="${1:?Usage: $0 stop VM_NAME}"
    info "Sending graceful shutdown to: $name"
    $VIRSH shutdown "$name" || die "Failed to send shutdown"
    info "Shutdown signal sent. Waiting up to 30s..."

    local i=0
    while [[ $i -lt 30 ]]; do
        local state
        state=$($VIRSH domstate "$name" 2>/dev/null || echo "shut off")
        if [[ "$state" == "shut off" ]]; then
            info "Domain '$name' has shut down."
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done

    info "Timeout. Domain still running after 30s."
    info "Use '$0 destroy $name' to force-kill."
}

cmd_destroy() {
    local name="${1:?Usage: $0 destroy VM_NAME}"
    info "Force-destroying domain: $name"
    $VIRSH destroy "$name" || info "Domain may already be stopped."
}

cmd_undefine() {
    local name="${1:?Usage: $0 undefine VM_NAME}"
    local state
    state=$($VIRSH domstate "$name" 2>/dev/null || echo "shut off")
    if [[ "$state" == "running" ]]; then
        die "Domain '$name' is running. Stop it first."
    fi
    info "Undefining domain: $name"
    $VIRSH undefine "$name" --nvram 2>/dev/null || $VIRSH undefine "$name"
    info "Domain '$name' removed."
}

cmd_status() {
    local name="${1:?Usage: $0 status VM_NAME}"
    if ! $VIRSH dominfo "$name" &>/dev/null; then
        echo "Domain '$name' is not defined."
        return 1
    fi
    echo "=== Domain: $name ==="
    $VIRSH dominfo "$name"
    echo ""

    local xml
    xml=$($VIRSH dumpxml "$name" 2>/dev/null || true)
    if echo "$xml" | grep -q "xen-version"; then
        echo "Xen HVM emulation: ACTIVE"
        local xver
        xver=$(echo "$xml" | grep -oP 'xen-version=\S+' | head -1)
        echo "  $xver"
    else
        echo "Xen HVM emulation: NOT configured"
    fi
}

cmd_list() {
    info "Xen-on-KVM domains:"
    echo ""
    local domains
    domains=$($VIRSH list --all --name 2>/dev/null | grep -v '^$' || true)
    if [[ -z "$domains" ]]; then
        echo "  (no domains defined)"
        return 0
    fi

    printf "  %-30s %-12s %-10s\n" "NAME" "STATE" "XEN-SHIM"
    printf "  %-30s %-12s %-10s\n" "----" "-----" "--------"
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        local state
        state=$($VIRSH domstate "$name" 2>/dev/null || echo "unknown")
        local xen_shim="no"
        local xml
        xml=$($VIRSH dumpxml "$name" 2>/dev/null || true)
        if echo "$xml" | grep -q "xen-version"; then
            xen_shim="yes"
        fi
        printf "  %-30s %-12s %-10s\n" "$name" "$state" "$xen_shim"
    done <<< "$domains"
}

cmd_verify() {
    local name="${1:?Usage: $0 verify VM_NAME}"

    local state
    state=$($VIRSH domstate "$name" 2>/dev/null || echo "undefined")
    if [[ "$state" != "running" ]]; then
        die "Domain '$name' is not running (state: $state)"
    fi

    echo "=== Verifying Xen emulation for: $name ==="

    local xml
    xml=$($VIRSH dumpxml "$name" 2>/dev/null || true)

    local checks_passed=0 checks_total=0

    checks_total=$((checks_total + 1))
    if echo "$xml" | grep -q "xen-version"; then
        echo "  [PASS] QEMU Xen emulation flags present"
        checks_passed=$((checks_passed + 1))
    else
        echo "  [FAIL] No xen-version in domain XML"
    fi

    checks_total=$((checks_total + 1))
    if echo "$xml" | grep -q "kernel-irqchip=split"; then
        echo "  [PASS] kernel-irqchip=split configured"
        checks_passed=$((checks_passed + 1))
    else
        echo "  [FAIL] kernel-irqchip=split not found"
    fi

    checks_total=$((checks_total + 1))
    if echo "$xml" | grep -q "xen-vapic"; then
        echo "  [PASS] xen-vapic CPU flag enabled"
        checks_passed=$((checks_passed + 1))
    else
        echo "  [WARN] xen-vapic not found (optional but recommended)"
    fi

    checks_total=$((checks_total + 1))
    if echo "$xml" | grep -q "xen-evtchn=on"; then
        echo "  [PASS] Xen event channel emulation enabled"
        checks_passed=$((checks_passed + 1))
    else
        echo "  [INFO] xen-evtchn not explicitly enabled"
    fi

    checks_total=$((checks_total + 1))
    if echo "$xml" | grep -q "xen-gnttab=on"; then
        echo "  [PASS] Xen grant table emulation enabled"
        checks_passed=$((checks_passed + 1))
    else
        echo "  [INFO] xen-gnttab not explicitly enabled"
    fi

    echo ""
    echo "  Checks: $checks_passed/$checks_total passed"
    [[ $checks_passed -ge 2 ]] && echo "  Xen-on-KVM emulation: VERIFIED"
}

cmd_generate_xml() {
    local name="${1:?Usage: $0 generate-xml VM_NAME DISK [MEM_MB] [VCPUS]}"
    local disk="${2:?Usage: $0 generate-xml VM_NAME DISK [MEM_MB] [VCPUS]}"
    local mem="${3:-2048}"
    local vcpus="${4:-2}"
    generate_domain_xml "$name" "$disk" "$mem" "$vcpus"
}

# ── GPU / PCI Passthrough for AI Inference VMs ────────────────────
#
# PCI address format: DDDD:BB:SS.F (domain:bus:slot.function)
# Example: 0000:01:00.0 (typical discrete GPU)
#
# Prerequisites:
#   1. IOMMU enabled in kernel/hypervisor (intel_iommu=on or amd_iommu=on)
#   2. GPU bound to vfio-pci driver (not nvidia/amdgpu)
#   3. All devices in same IOMMU group passed through together
#
# For AI inference: pass a GPU + enough memory for model loading.
# Typical config: 16GB+ RAM, 4+ vCPUs, one discrete GPU.

parse_pci_addr() {
    local addr="$1"
    if [[ "$addr" =~ ^([0-9a-fA-F]{4}):([0-9a-fA-F]{2}):([0-9a-fA-F]{2})\.([0-9a-fA-F])$ ]]; then
        PCI_DOMAIN="${BASH_REMATCH[1]}"
        PCI_BUS="${BASH_REMATCH[2]}"
        PCI_SLOT="${BASH_REMATCH[3]}"
        PCI_FUNC="${BASH_REMATCH[4]}"
    elif [[ "$addr" =~ ^([0-9a-fA-F]{2}):([0-9a-fA-F]{2})\.([0-9a-fA-F])$ ]]; then
        PCI_DOMAIN="0000"
        PCI_BUS="${BASH_REMATCH[1]}"
        PCI_SLOT="${BASH_REMATCH[2]}"
        PCI_FUNC="${BASH_REMATCH[3]}"
    else
        die "Invalid PCI address: $addr (expected DDDD:BB:SS.F or BB:SS.F)"
    fi
}

generate_gpu_hostdev_xml() {
    local addr="$1"
    parse_pci_addr "$addr"
    cat << PCIEOF
        <hostdev type="pci" mode="subsystem" managed="yes">
            <driver name="vfio"/>
            <source>
                <address domain="0x${PCI_DOMAIN}" bus="0x${PCI_BUS}"
                         slot="0x${PCI_SLOT}" function="0x${PCI_FUNC}"/>
            </source>
        </hostdev>
PCIEOF
}

generate_gpu_domain_xml() {
    local name="$1"
    local disk="$2"
    local pci_addrs="$3"
    local mem="${4:-16384}"
    local vcpus="${5:-4}"
    local disk_abs
    disk_abs="$(realpath "$disk" 2>/dev/null || echo "$disk")"

    local disk_type="file"
    local disk_source_attr="file"
    local disk_driver_type="qcow2"
    if [[ "$disk_abs" == /dev/* ]]; then
        disk_type="block"
        disk_source_attr="dev"
        disk_driver_type="raw"
    elif file "$disk_abs" 2>/dev/null | grep -qi "raw\|data"; then
        disk_driver_type="raw"
    fi

    local ovmf=""
    for f in /usr/share/edk2/ovmf/OVMF_CODE.fd \
             /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/edk2/xen/OVMF.fd; do
        [[ -f "$f" ]] && ovmf="$f" && break
    done

    local loader_xml=""
    if [[ -n "$ovmf" ]]; then
        loader_xml="<loader readonly=\"yes\" type=\"pflash\">$ovmf</loader>"
    fi

    local hostdev_block=""
    local IFS=','
    for addr in $pci_addrs; do
        hostdev_block+="$(generate_gpu_hostdev_xml "$addr")"$'\n'
    done
    unset IFS

    cat << XMLEOF
<domain type="kvm" xmlns:qemu="http://libvirt.org/schemas/domain/qemu/1.0">
    <name>$name</name>
    <memory unit="MiB">$mem</memory>
    <currentMemory unit="MiB">$mem</currentMemory>
    <vcpu placement="static">$vcpus</vcpu>
    <cpu mode="host-passthrough"/>
    <os>
        <type arch="x86_64" machine="q35">hvm</type>
        $loader_xml
        <boot dev="hd"/>
    </os>
    <features>
        <pae/>
        <acpi/>
        <apic/>
        <kvm>
            <hidden state="on"/>
        </kvm>
        <ioapic driver="kvm"/>
    </features>
    <clock offset="utc">
        <timer name="rtc" tickpolicy="catchup"/>
        <timer name="pit" tickpolicy="delay"/>
        <timer name="hpet" present="no"/>
    </clock>
    <on_poweroff>destroy</on_poweroff>
    <on_reboot>destroy</on_reboot>
    <on_crash>destroy</on_crash>
    <devices>
        <emulator>/usr/bin/qemu-system-x86_64</emulator>
        <disk type="$disk_type" device="disk">
            <driver name="qemu" type="$disk_driver_type" cache="none"/>
            <source ${disk_source_attr}="${disk_abs}"/>
            <target dev="vda" bus="virtio"/>
        </disk>
        <interface type="user">
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
            <source mode="bind" path="/var/run/qubes/qubesdb.${name}.sock"/>
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
$hostdev_block    </devices>
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

cmd_gpu_define() {
    local name="${1:?Usage: $0 gpu-define VM_NAME DISK PCI_ADDR[,PCI_ADDR2,...] [MEM_MB] [VCPUS]}"
    local disk="${2:?Provide disk image path}"
    local pci_addrs="${3:?Provide PCI address(es), comma-separated (e.g. 01:00.0,01:00.1)}"
    local mem="${4:-16384}"
    local vcpus="${5:-4}"

    [[ -e "$disk" ]] || die "Disk image not found: $disk"

    local IFS=','
    for addr in $pci_addrs; do
        parse_pci_addr "$addr"
        local sysfs="/sys/bus/pci/devices/0000:${PCI_BUS}:${PCI_SLOT}.${PCI_FUNC}/driver"
        if [[ -L "$sysfs" ]]; then
            local current_drv
            current_drv="$(basename "$(readlink "$sysfs")")"
            if [[ "$current_drv" != "vfio-pci" ]]; then
                info "WARNING: $addr is bound to '$current_drv', not vfio-pci"
                info "  Bind with: echo $addr > /sys/bus/pci/drivers/$current_drv/unbind"
                info "             echo $addr > /sys/bus/pci/drivers/vfio-pci/bind"
            fi
        fi
    done
    unset IFS

    if $VIRSH dominfo "$name" &>/dev/null; then
        info "Domain '$name' already defined. Undefining first..."
        $VIRSH destroy "$name" 2>/dev/null || true
        $VIRSH undefine "$name" --nvram 2>/dev/null || $VIRSH undefine "$name" 2>/dev/null || true
    fi

    info "Defining GPU-passthrough Xen-on-KVM domain: $name"
    info "  PCI devices: $pci_addrs"
    info "  Memory: ${mem}MB, vCPUs: $vcpus"
    local xml
    xml="$(generate_gpu_domain_xml "$name" "$disk" "$pci_addrs" "$mem" "$vcpus")"
    echo "$xml" | $VIRSH define /dev/stdin
    info "Domain '$name' defined with GPU passthrough."
    info "  Start: $0 start $name"
    info "  Verify GPU inside guest: lspci | grep -i vga"
}

cmd_gpu_list() {
    info "PCI devices suitable for passthrough:"
    echo ""

    if ! command -v lspci &>/dev/null; then
        die "lspci not installed (pciutils package)"
    fi

    printf "  %-14s %-8s %-50s\n" "ADDRESS" "DRIVER" "DEVICE"
    printf "  %-14s %-8s %-50s\n" "-------" "------" "------"

    local found=0
    while IFS= read -r line; do
        local addr desc
        addr="$(echo "$line" | awk '{print $1}')"
        desc="$(echo "$line" | cut -d' ' -f2-)"

        local drv="(none)"
        local sysfs="/sys/bus/pci/devices/0000:${addr}/driver"
        if [[ -L "$sysfs" ]]; then
            drv="$(basename "$(readlink "$sysfs")")"
        fi

        case "$desc" in
            *VGA*|*3D*|*Display*|*GPU*|*Accelerator*)
                printf "  %-14s %-8s %-50s\n" "$addr" "$drv" "$desc"
                found=$((found + 1))
                ;;
        esac
    done < <(lspci 2>/dev/null || true)

    echo ""
    if [[ $found -eq 0 ]]; then
        info "No GPU/accelerator devices found."
    else
        info "$found GPU/accelerator device(s) found."
        info ""
        info "To use a device for passthrough:"
        info "  1. Bind to vfio-pci (unbind from nvidia/amdgpu first)"
        info "  2. $0 gpu-define VM_NAME DISK.qcow2 BUS:SLOT.FUNC [MEM_MB] [VCPUS]"
    fi
}

ACTION="${1:?Usage: $0 <action> [args...] — see below}"
shift

case "$ACTION" in
    define)       cmd_define "$@" ;;
    install)      cmd_install "$@" ;;
    start)        cmd_start "$@" ;;
    stop)         cmd_stop "$@" ;;
    destroy)      cmd_destroy "$@" ;;
    undefine)     cmd_undefine "$@" ;;
    status)       cmd_status "$@" ;;
    list)         cmd_list ;;
    verify)       cmd_verify "$@" ;;
    console)      cmd_console "$@" ;;
    generate-xml) cmd_generate_xml "$@" ;;
    gpu-define)   cmd_gpu_define "$@" ;;
    gpu-list)     cmd_gpu_list ;;
    *)
        echo "Unknown action: $ACTION"
        echo ""
        echo "Usage: $0 <action> [args...]"
        echo ""
        echo "VM management:"
        echo "  define       VM_NAME DISK [MEM] [VCPUS]        Standard Xen-on-KVM domain"
        echo "  install      VM_NAME DISK ISO [MEM] [VCPUS]    Install from ISO"
        echo "  start        VM_NAME                            Start domain"
        echo "  stop         VM_NAME                            Graceful shutdown"
        echo "  destroy      VM_NAME                            Force kill"
        echo "  undefine     VM_NAME                            Remove domain"
        echo "  status       VM_NAME                            Show domain info"
        echo "  list                                            List all domains"
        echo "  verify       VM_NAME                            Verify Xen emulation"
        echo "  console      VM_NAME                            Serial console"
        echo "  generate-xml VM_NAME DISK [MEM] [VCPUS]        Print XML only"
        echo ""
        echo "GPU passthrough (AI inference):"
        echo "  gpu-define   VM_NAME DISK PCI[,PCI2] [MEM] [VCPUS]"
        echo "  gpu-list                                        Show available GPUs"
        exit 1
        ;;
esac
