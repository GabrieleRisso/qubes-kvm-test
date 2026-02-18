#!/usr/bin/env python3
"""Host-side QubesDB config injector for KVM VMs.

Sends key=value configuration entries through the virtio-serial Unix socket
to a guest VM. The guest reads these with qubesdb-config-read.

Protocol: newline-delimited key=value pairs, terminated by a blank line.

Usage:
    qubesdb-config-inject.py SOCKET_PATH [KEY=VALUE ...]
    echo "name=work" | qubesdb-config-inject.py SOCKET_PATH
"""
import json
import socket
import sys
import os

QUBESDB_HEADER = b"QUBESDB-KVM-CONFIG\n"
QUBESDB_FOOTER = b"\nQUBESDB-END\n"


def inject(sock_path: str, entries: dict) -> bool:
    payload = QUBESDB_HEADER.decode()
    for k, v in entries.items():
        payload += f"{k}={v}\n"
    payload += QUBESDB_FOOTER.decode()

    import shutil
    import subprocess

    socat = shutil.which("socat")
    if socat:
        try:
            proc = subprocess.run(
                [socat, "-t5", "-", f"UNIX-CONNECT:{sock_path}"],
                input=payload.encode(),
                capture_output=True,
                timeout=15,
            )
            if proc.returncode == 0:
                print(f"Injected {len(entries)} entries via {sock_path}")
                return True
            print(f"socat error: {proc.stderr.decode()}", file=sys.stderr)
            return False
        except subprocess.TimeoutExpired:
            print(f"TIMEOUT: Guest may not be reading {sock_path} yet", file=sys.stderr)
            return False

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(10)
    try:
        sock.connect(sock_path)
        sock.sendall(payload.encode())
        print(f"Injected {len(entries)} entries via {sock_path}")
        return True
    except socket.timeout:
        print(f"TIMEOUT: Guest may not be reading {sock_path} yet", file=sys.stderr)
        return False
    except (ConnectionRefusedError, FileNotFoundError, OSError) as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return False
    finally:
        sock.close()


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} SOCKET_PATH [KEY=VALUE ...]", file=sys.stderr)
        sys.exit(1)

    sock_path = sys.argv[1]
    entries = {}

    for arg in sys.argv[2:]:
        if "=" in arg:
            k, v = arg.split("=", 1)
            entries[k] = v

    if not sys.stdin.isatty():
        for line in sys.stdin:
            line = line.strip()
            if "=" in line:
                k, v = line.split("=", 1)
                entries[k] = v

    if not entries:
        entries = {
            "/name": os.environ.get("VM_NAME", "qubes-kvm-node1"),
            "/type": "AppVM",
            "/label": "green",
            "/netvm": "sys-firewall",
            "/memory": os.environ.get("VM_MEM", "4096"),
            "/vcpus": os.environ.get("VM_CPUS", "2"),
            "/qubes-vm-updateable": "False",
            "/qubes-base-template": "fedora-41",
            "/qubes-vm-persistence": "full",
            "/qubes-ip": "10.137.0.100",
            "/qubes-netmask": "255.255.255.255",
            "/qubes-gateway": "10.137.0.1",
            "/qubes-primary-dns": "10.139.1.1",
            "/qubes-secondary-dns": "10.139.1.2",
        }
        print("Using default QubesDB entries.")

    ok = inject(sock_path, entries)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
