#!/bin/bash
# provision-guest.sh — Run inside a Qubes-on-KVM guest to install all Qubes infrastructure
#
# This script installs:
#   1. Xen CPUID shim (makes guest report Xen hypervisor)
#   2. QubesDB config reader as a systemd service
#   3. Qubes RPC framework
#   4. Network isolation (nftables rules)
#   5. Qubes agent helpers
#
# Usage (run inside the guest as root):
#   sudo bash provision-guest.sh
set -euo pipefail

log()  { echo "[provision] $*"; }
err()  { echo "[provision] ERROR: $*" >&2; }

[[ "$(id -u)" -eq 0 ]] || { err "Must run as root"; exit 1; }

QUBESDB_DIR="/var/lib/qubesdb"
QUBES_RPC_DIR="/etc/qubes-rpc"
QUBES_AGENT_DIR="/usr/local/lib/qubes"

mkdir -p "$QUBESDB_DIR" "$QUBES_RPC_DIR" "$QUBES_AGENT_DIR"

########################################
# 1. Xen CPUID Shim
########################################
install_xen_shim() {
    log "Installing Xen CPUID shim..."

    cat > /usr/local/bin/qubes-xen-detect << 'SHIMEOF'
#!/bin/bash
# Qubes-on-KVM Xen detection shim
# Reports hypervisor type based on QubesDB config
QUBESDB_CACHE="/var/lib/qubesdb/qubesdb.json"

if [ -f "$QUBESDB_CACHE" ]; then
    echo "xen-kvm"
    exit 0
fi

if [ -e /dev/virtio-ports/org.qubes-os.qubesdb ]; then
    echo "xen-kvm"
    exit 0
fi

if grep -q hypervisor /proc/cpuinfo 2>/dev/null; then
    if [ -f /sys/hypervisor/type ]; then
        cat /sys/hypervisor/type
    else
        echo "kvm"
    fi
    exit 0
fi

echo "bare-metal"
exit 1
SHIMEOF
    chmod +x /usr/local/bin/qubes-xen-detect

    mkdir -p /sys/hypervisor 2>/dev/null || true
    cat > /usr/local/bin/qubes-hypervisor-setup << 'HSETUP'
#!/bin/bash
# Creates /etc/qubes/hypervisor to fake Xen presence for Qubes tools
mkdir -p /etc/qubes
cat > /etc/qubes/hypervisor << EOF2
type=xen-kvm
version=4.19
backend=kvm
qubesdb=virtio-serial
EOF2
HSETUP
    chmod +x /usr/local/bin/qubes-hypervisor-setup
    /usr/local/bin/qubes-hypervisor-setup

    log "  Xen shim installed: /usr/local/bin/qubes-xen-detect"
    log "  Hypervisor config:  /etc/qubes/hypervisor"
}

########################################
# 2. QubesDB Reader Service
########################################
install_qubesdb_service() {
    log "Installing QubesDB reader service..."

    cat > /usr/local/bin/qubesdb-config-read << 'READEREOF'
#!/usr/bin/env python3
"""Guest-side QubesDB config reader — reads from virtio-serial, caches locally."""
import json, os, sys, time

VIRTIO_PORT = "/dev/virtio-ports/org.qubes-os.qubesdb"
CACHE_DIR = "/var/lib/qubesdb"
CACHE_FILE = os.path.join(CACHE_DIR, "qubesdb.json")

def read_from_virtio(timeout=60):
    if not os.path.exists(VIRTIO_PORT):
        waited = 0
        while not os.path.exists(VIRTIO_PORT) and waited < timeout:
            time.sleep(1); waited += 1
        if not os.path.exists(VIRTIO_PORT):
            return {}
    entries = {}
    try:
        with open(VIRTIO_PORT, "rb") as f:
            data = b""
            deadline = time.time() + timeout
            while time.time() < deadline:
                chunk = f.read(4096)
                if chunk:
                    data += chunk
                    if b"QUBESDB-END" in data:
                        break
                else:
                    time.sleep(0.1)
            for line in data.decode("utf-8", errors="replace").splitlines():
                line = line.strip()
                if line in ("QUBESDB-KVM-CONFIG", "QUBESDB-END", ""):
                    continue
                if "=" in line:
                    k, v = line.split("=", 1)
                    entries[k] = v
    except (IOError, OSError) as e:
        print(f"ERROR: {e}", file=sys.stderr)
    return entries

def save_cache(entries):
    os.makedirs(CACHE_DIR, exist_ok=True)
    with open(CACHE_FILE, "w") as f:
        json.dump(entries, f, indent=2)
    edir = os.path.join(CACHE_DIR, "entries")
    os.makedirs(edir, exist_ok=True)
    for k, v in entries.items():
        with open(os.path.join(edir, k.lstrip("/").replace("/", "_")), "w") as f:
            f.write(v)

def load_cache():
    if os.path.exists(CACHE_FILE):
        with open(CACHE_FILE) as f:
            return json.load(f)
    return {}

if __name__ == "__main__":
    if "--get" in sys.argv:
        idx = sys.argv.index("--get")
        if idx + 1 < len(sys.argv):
            e = load_cache()
            k = sys.argv[idx + 1]
            if k in e: print(e[k])
            else: sys.exit(1)
        sys.exit(0)
    if "--list" in sys.argv:
        for k, v in sorted(load_cache().items()):
            print(f"{k} = {v}")
        sys.exit(0)
    if "--json" in sys.argv:
        print(json.dumps(load_cache(), indent=2))
        sys.exit(0)

    entries = read_from_virtio()
    if entries:
        save_cache(entries)
        print(f"QubesDB: loaded {len(entries)} entries")
    else:
        cached = load_cache()
        if cached:
            print(f"Using {len(cached)} cached entries")
        else:
            print("WARNING: No QubesDB config available", file=sys.stderr)
READEREOF
    chmod +x /usr/local/bin/qubesdb-config-read

    cat > /etc/systemd/system/qubesdb-config-read.service << 'SVCEOF'
[Unit]
Description=QubesDB Configuration Reader (KVM virtio-serial)
DefaultDependencies=no
After=systemd-udevd.service
Before=network-pre.target qubes-network.service
Wants=systemd-udevd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/qubesdb-config-read
TimeoutStartSec=90
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable qubesdb-config-read.service
    log "  QubesDB service installed and enabled"
}

########################################
# 3. Qubes RPC Framework
########################################
install_qubes_rpc() {
    log "Installing Qubes RPC framework..."

    cat > "$QUBES_RPC_DIR/qubes.VMShell" << 'EOF'
#!/bin/bash
exec /bin/bash
EOF
    chmod +x "$QUBES_RPC_DIR/qubes.VMShell"

    cat > "$QUBES_RPC_DIR/qubes.Filecopy" << 'EOF'
#!/bin/bash
exec /usr/lib/qubes/qubes-receive-appmenus 2>/dev/null || cat > /dev/null
EOF
    chmod +x "$QUBES_RPC_DIR/qubes.Filecopy"

    cat > "$QUBES_RPC_DIR/qubes.GetAppmenus" << 'EOF'
#!/bin/bash
find /usr/share/applications -name "*.desktop" 2>/dev/null | head -50
EOF
    chmod +x "$QUBES_RPC_DIR/qubes.GetAppmenus"

    cat > "$QUBES_RPC_DIR/qubes.GetImageRGBA" << 'EOF'
#!/bin/bash
exec echo "QUBESIMG0\x00\x00\x00\x00"
EOF
    chmod +x "$QUBES_RPC_DIR/qubes.GetImageRGBA"

    cat > /usr/local/bin/qubes-rpc-dispatch << 'RPCEOF'
#!/bin/bash
# Minimal Qubes RPC dispatcher for KVM guests
RPC_SERVICE="$1"
shift
HANDLER="$QUBES_RPC_DIR/$RPC_SERVICE"
if [[ -x "$HANDLER" ]]; then
    exec "$HANDLER" "$@"
else
    echo "ERROR: Unknown RPC service: $RPC_SERVICE" >&2
    exit 1
fi
RPCEOF
    chmod +x /usr/local/bin/qubes-rpc-dispatch

    log "  Qubes RPC handlers installed in $QUBES_RPC_DIR"
}

########################################
# 4. Network Isolation (nftables)
########################################
install_network_isolation() {
    log "Installing network isolation rules..."

    cat > /usr/local/bin/qubes-firewall-setup << 'FWEOF'
#!/bin/bash
# Qubes-on-KVM network isolation via nftables
# Reads QubesDB for network config, applies restrictive rules

QUBESDB="/var/lib/qubesdb/qubesdb.json"

get_db() { python3 -c "import json; d=json.load(open('$QUBESDB')); print(d.get('$1',''))" 2>/dev/null; }

QUBES_IP="$(get_db /qubes-ip)"
QUBES_GW="$(get_db /qubes-gateway)"
QUBES_NETMASK="$(get_db /qubes-netmask)"
DNS1="$(get_db /qubes-primary-dns)"
DNS2="$(get_db /qubes-secondary-dns)"

if ! command -v nft &>/dev/null; then
    echo "nft not found, skipping firewall" >&2
    exit 0
fi

nft flush ruleset 2>/dev/null || true

nft -f - << NFTEOF
table inet qubes-firewall {
    chain input {
        type filter hook input priority 0; policy drop;
        ct state established,related accept
        iif "lo" accept
        icmp type echo-request accept
        tcp dport 22 accept
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
    }

    chain output {
        type filter hook output priority 0; policy accept;
        # Allow DNS
        $([ -n "$DNS1" ] && echo "udp dport 53 ip daddr $DNS1 accept")
        $([ -n "$DNS2" ] && echo "udp dport 53 ip daddr $DNS2 accept")
        # Allow established
        ct state established,related accept
    }
}
NFTEOF

echo "Firewall rules applied (qubes-firewall nftables)"
FWEOF
    chmod +x /usr/local/bin/qubes-firewall-setup

    cat > /etc/systemd/system/qubes-firewall.service << 'SVCEOF'
[Unit]
Description=Qubes-on-KVM Firewall (nftables)
After=qubesdb-config-read.service network-pre.target
Wants=qubesdb-config-read.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/qubes-firewall-setup
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable qubes-firewall.service 2>/dev/null || true
    log "  Firewall service installed"
}

########################################
# 5. Qubes Agent Helpers
########################################
install_qubes_agent() {
    log "Installing Qubes agent helpers..."

    cat > "$QUBES_AGENT_DIR/qubes-vm-type" << 'EOF'
#!/bin/bash
qubesdb-config-read --get /type 2>/dev/null || echo "AppVM"
EOF
    chmod +x "$QUBES_AGENT_DIR/qubes-vm-type"

    cat > "$QUBES_AGENT_DIR/qubes-vm-name" << 'EOF'
#!/bin/bash
qubesdb-config-read --get /name 2>/dev/null || hostname
EOF
    chmod +x "$QUBES_AGENT_DIR/qubes-vm-name"

    cat > "$QUBES_AGENT_DIR/qubes-vm-label" << 'EOF'
#!/bin/bash
qubesdb-config-read --get /label 2>/dev/null || echo "green"
EOF
    chmod +x "$QUBES_AGENT_DIR/qubes-vm-label"

    cat > /usr/local/bin/qubes-vm-info << 'INFOEOF'
#!/bin/bash
QDB="/var/lib/qubesdb/qubesdb.json"
qdb() { python3 -c "import json; d=json.load(open('$QDB')); print(d.get('$1','unknown'))" 2>/dev/null || echo "unknown"; }

echo "=== Qubes-on-KVM VM Info ==="
echo "Name:     $(qdb /name)"
echo "Type:     $(qdb /type)"
echo "Label:    $(qdb /label)"
echo "Hyper:    $(qubes-xen-detect 2>/dev/null || echo unknown)"
echo "Kernel:   $(uname -r)"
echo "CPUs:     $(nproc)"
echo "Memory:   $(free -h | awk '/Mem:/{print $2}')"
echo ""
echo "--- QubesDB ---"
qubesdb-config-read --list 2>/dev/null || echo "(no entries)"
echo ""
echo "--- Network ---"
ip -4 addr show scope global 2>/dev/null | grep -oP 'inet \K[\d./]+'
echo ""
echo "--- Qubes RPC ---"
ls /etc/qubes-rpc/ 2>/dev/null || echo "(none)"
echo ""
echo "--- Firewall ---"
sudo nft list ruleset 2>/dev/null | head -5 || echo "(no nft)"
INFOEOF
    chmod +x /usr/local/bin/qubes-vm-info

    log "  Agent helpers installed in $QUBES_AGENT_DIR"
}

########################################
# 6. MOTD
########################################
install_motd() {
    cat > /etc/motd << 'MOTDEOF'

  ╔═══════════════════════════════════════════════╗
  ║         Qubes-on-KVM Guest VM                 ║
  ║  Run 'qubes-vm-info' for status               ║
  ║  Run 'qubesdb-config-read --list' for config   ║
  ╚═══════════════════════════════════════════════╝

MOTDEOF
}

########################################
# MAIN
########################################
log "=== Qubes-on-KVM Guest Provisioning ==="
install_xen_shim
install_qubesdb_service
install_qubes_rpc
install_network_isolation
install_qubes_agent
install_motd
log ""
log "=== Provisioning Complete ==="
log "  Xen detect:  qubes-xen-detect"
log "  QubesDB:     qubesdb-config-read --list"
log "  VM info:     qubes-vm-info"
log "  Firewall:    qubes-firewall-setup"
log "  RPC:         ls /etc/qubes-rpc/"
log ""
log "Reboot to activate all services, or run:"
log "  systemctl start qubesdb-config-read"
log "  qubes-firewall-setup"
