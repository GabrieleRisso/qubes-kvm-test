#!/usr/bin/env python3
"""Guest-side QubesDB config reader for KVM VMs.

Reads configuration from the virtio-serial port and caches it locally.
Designed to run early in boot as a systemd service.

Usage:
    qubesdb-config-read.py                 # read and cache config
    qubesdb-config-read.py --get KEY       # get a specific key
    qubesdb-config-read.py --list          # list all cached entries
    qubesdb-config-read.py --json          # dump as JSON
"""
import json
import os
import sys
import time

VIRTIO_PORT = "/dev/virtio-ports/org.qubes-os.qubesdb"
CACHE_DIR = "/var/lib/qubesdb"
CACHE_FILE = os.path.join(CACHE_DIR, "qubesdb.json")

QUBESDB_HEADER = b"QUBESDB-KVM-CONFIG\n"
QUBESDB_FOOTER = b"\nQUBESDB-END\n"


def read_from_virtio(timeout: int = 30) -> dict:
    """Read config from the virtio-serial port."""
    if not os.path.exists(VIRTIO_PORT):
        print(f"Waiting for {VIRTIO_PORT}...", file=sys.stderr)
        waited = 0
        while not os.path.exists(VIRTIO_PORT) and waited < timeout:
            time.sleep(1)
            waited += 1
        if not os.path.exists(VIRTIO_PORT):
            print(f"ERROR: {VIRTIO_PORT} not found after {timeout}s", file=sys.stderr)
            return {}

    print(f"Reading QubesDB from {VIRTIO_PORT}...", file=sys.stderr)
    entries = {}
    try:
        with open(VIRTIO_PORT, "rb") as f:
            data = b""
            deadline = time.time() + timeout
            while time.time() < deadline:
                chunk = f.read(4096)
                if chunk:
                    data += chunk
                    if QUBESDB_FOOTER in data:
                        break
                else:
                    time.sleep(0.1)

            text = data.decode("utf-8", errors="replace")
            for line in text.splitlines():
                line = line.strip()
                if line in ("QUBESDB-KVM-CONFIG", "QUBESDB-END", ""):
                    continue
                if "=" in line:
                    k, v = line.split("=", 1)
                    entries[k] = v
    except (IOError, OSError) as e:
        print(f"ERROR reading {VIRTIO_PORT}: {e}", file=sys.stderr)

    return entries


def save_cache(entries: dict):
    os.makedirs(CACHE_DIR, exist_ok=True)
    with open(CACHE_FILE, "w") as f:
        json.dump(entries, f, indent=2)
    print(f"Cached {len(entries)} entries to {CACHE_FILE}", file=sys.stderr)

    qubesdb_dir = os.path.join(CACHE_DIR, "entries")
    os.makedirs(qubesdb_dir, exist_ok=True)
    for k, v in entries.items():
        safe_key = k.lstrip("/").replace("/", "_")
        with open(os.path.join(qubesdb_dir, safe_key), "w") as f:
            f.write(v)


def load_cache() -> dict:
    if os.path.exists(CACHE_FILE):
        with open(CACHE_FILE) as f:
            return json.load(f)
    return {}


def main():
    if "--get" in sys.argv:
        idx = sys.argv.index("--get")
        if idx + 1 < len(sys.argv):
            key = sys.argv[idx + 1]
            entries = load_cache()
            if key in entries:
                print(entries[key])
            else:
                print(f"Key not found: {key}", file=sys.stderr)
                sys.exit(1)
        return

    if "--list" in sys.argv:
        entries = load_cache()
        for k, v in sorted(entries.items()):
            print(f"{k} = {v}")
        return

    if "--json" in sys.argv:
        entries = load_cache()
        print(json.dumps(entries, indent=2))
        return

    entries = read_from_virtio()
    if entries:
        save_cache(entries)
        print(f"QubesDB: {len(entries)} entries loaded", file=sys.stderr)
        for k, v in sorted(entries.items()):
            print(f"  {k} = {v}", file=sys.stderr)
    else:
        cached = load_cache()
        if cached:
            print(f"No new data; using {len(cached)} cached entries", file=sys.stderr)
        else:
            print("WARNING: No QubesDB configuration available", file=sys.stderr)


if __name__ == "__main__":
    main()
