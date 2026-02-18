# qubes-kvm-test

Self-contained testing toolkit for the Qubes OS KVM fork architecture.  
Validates KVM, Xen-on-KVM emulation, GPU passthrough, and ARM64 support on any capable machine.

## Quick Start

```bash
git clone https://github.com/GabrieleRisso/qubes-kvm-test.git
cd qubes-kvm-test

# Full pipeline: setup → test → agent → report
bash run-all.sh

# Or step by step:
bash setup.sh              # Install deps (selective, no full upgrade)
bash run-all.sh test       # Run E2E tests
bash run-all.sh agent      # Start remote agent
bash run-all.sh check      # Quick readiness check
bash setup.sh fix          # Fix glibc/QEMU mismatches
```

## Requirements

- Linux with KVM support (`/dev/kvm`)
- EndeavourOS / Arch Linux recommended (uses `pacman`, `yay`, `uv`)
- 8GB+ RAM, 4+ CPU cores
- IOMMU for GPU passthrough (optional)

## Structure

```
qubes-kvm-test/
├── run-all.sh                  # Single entry point
├── setup.sh                    # Machine setup (deps, KVM, agent)
├── scripts/
│   └── xen-kvm-bridge.sh      # Xen-on-KVM VM management via libvirt
├── agent/
│   ├── agent.py                # FastAPI remote dev agent
│   └── requirements.txt        # Python dependencies
├── test/
│   ├── e2e-kvm-hardware.sh     # 7-phase E2E test suite
│   └── results/                # Test output logs
├── configs/                    # VM configuration templates
└── vm-images/                  # Disk images (gitignored)
```

## What Gets Tested

| Phase | Test | Description |
|-------|------|-------------|
| 1 | Prerequisites | /dev/kvm, QEMU, libvirt, nested virt |
| 2 | VM Boot | QEMU+KVM basic boot to BIOS |
| 3 | Xen Emulation | QEMU xen-version=0x40013 boot |
| 4 | Bridge Script | xen-kvm-bridge.sh XML generation |
| 5 | ARM64 | aarch64 UEFI firmware boot |
| 6 | GPU | PCI device discovery, VFIO |
| 7 | Agent | FastAPI service health check |

## Package Management

This repo uses **selective** updates only — no `pacman -Syu`:

- `pacman -S --needed` for official packages
- `yay -S --needed` for AUR packages
- `uv` for Python virtual environments

To fix specific version mismatches (e.g., glibc):
```bash
bash setup.sh fix
```

## Remote Agent

The agent provides a REST API for remote development:

```
GET  /health          # Health check
GET  /status          # System info (KVM, GPU, IOMMU, memory)
POST /exec            # Execute shell command
GET  /vms             # List Xen-on-KVM domains
GET  /gpu             # List GPU devices
POST /crawl           # Web content extraction
WS   /ws/shell        # Live terminal WebSocket
```

Access docs at `http://<machine-ip>:8420/docs`

## License

Part of the Qubes OS KVM fork project.  
Qubes OS is licensed under GPLv2. See [qubes-os.org](https://www.qubes-os.org/).
