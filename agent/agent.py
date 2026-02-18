#!/usr/bin/env python3
"""
qubes-kvm-agent — Remote development agent for the Lenovo KVM host.

Runs on the Lenovo T15 and provides:
  - Shell command execution (build, test, VM management)
  - System status (KVM, libvirt, IOMMU, GPU)
  - VM lifecycle (define, start, stop, status via xen-kvm-bridge.sh)
  - Web crawl (fetch docs, check URLs via crawl4ai)
  - WebSocket live terminal output
  - File read/write for remote editing

Access from Qubes/Cursor:
  http://lenovo-ip:8420/docs   (interactive API docs)
  ws://lenovo-ip:8420/ws/shell (live terminal WebSocket)
"""

import asyncio
import json
import os
import platform
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

app = FastAPI(
    title="Qubes KVM Agent",
    version="0.1.0",
    description="Remote development agent for Qubes KVM fork on Lenovo T15",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

PROJECT_DIR = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = PROJECT_DIR / "scripts"
BRIDGE_SCRIPT = SCRIPTS_DIR / "xen-kvm-bridge.sh"
RESULTS_DIR = PROJECT_DIR / "test" / "results"

BOOT_TIME = time.time()


# ── Models ───────────────────────────────────────────────────────

class CommandRequest(BaseModel):
    command: str
    cwd: Optional[str] = None
    timeout: int = 300

class CommandResult(BaseModel):
    exit_code: int
    stdout: str
    stderr: str
    duration_ms: int

class CrawlRequest(BaseModel):
    url: str
    extract_text: bool = True
    extract_links: bool = False

class FileReadRequest(BaseModel):
    path: str
    offset: int = 0
    limit: int = 0

class FileWriteRequest(BaseModel):
    path: str
    content: str


# ── Helpers ──────────────────────────────────────────────────────

def run_cmd(cmd: str, cwd: str | None = None, timeout: int = 300) -> CommandResult:
    start = time.monotonic()
    try:
        r = subprocess.run(
            cmd, shell=True, capture_output=True, text=True,
            cwd=cwd or str(PROJECT_DIR), timeout=timeout,
        )
        duration = int((time.monotonic() - start) * 1000)
        return CommandResult(
            exit_code=r.returncode,
            stdout=r.stdout[-50000:],
            stderr=r.stderr[-10000:],
            duration_ms=duration,
        )
    except subprocess.TimeoutExpired:
        duration = int((time.monotonic() - start) * 1000)
        return CommandResult(exit_code=124, stdout="", stderr="TIMEOUT", duration_ms=duration)


def get_system_info() -> dict:
    import psutil

    kvm_present = os.path.exists("/dev/kvm")

    gpu_devices = []
    try:
        r = subprocess.run(
            ["lspci"], capture_output=True, text=True, timeout=5
        )
        for line in r.stdout.splitlines():
            if any(kw in line.upper() for kw in ["VGA", "3D", "DISPLAY", "GPU", "ACCELERATOR"]):
                gpu_devices.append(line.strip())
    except Exception:
        pass

    nested = "unknown"
    for path in [
        "/sys/module/kvm_intel/parameters/nested",
        "/sys/module/kvm_amd/parameters/nested",
    ]:
        if os.path.exists(path):
            with open(path) as f:
                val = f.read().strip()
            nested = val in ("Y", "1")
            break

    iommu_groups = 0
    iommu_path = Path("/sys/kernel/iommu_groups")
    if iommu_path.exists():
        iommu_groups = len(list(iommu_path.iterdir()))

    libvirt_active = False
    try:
        r = subprocess.run(
            ["systemctl", "is-active", "libvirtd"],
            capture_output=True, text=True, timeout=5,
        )
        libvirt_active = r.stdout.strip() == "active"
    except Exception:
        pass

    return {
        "hostname": platform.node(),
        "arch": platform.machine(),
        "kernel": platform.release(),
        "cpu_count": psutil.cpu_count(),
        "memory_gb": round(psutil.virtual_memory().total / (1024**3), 1),
        "disk_free_gb": round(psutil.disk_usage("/").free / (1024**3), 1),
        "kvm_present": kvm_present,
        "nested_virt": nested,
        "iommu_groups": iommu_groups,
        "gpu_devices": gpu_devices,
        "libvirt_active": libvirt_active,
        "uptime_seconds": int(time.time() - BOOT_TIME),
        "python": sys.version.split()[0],
        "project_dir": str(PROJECT_DIR),
    }


# ── Routes ───────────────────────────────────────────────────────

@app.get("/health")
async def health():
    return {"status": "ok", "agent": "qubes-kvm-agent", "version": "0.1.0"}


@app.get("/status")
async def status():
    return get_system_info()


@app.post("/exec", response_model=CommandResult)
async def exec_command(req: CommandRequest):
    """Execute a shell command and return output."""
    return await asyncio.to_thread(run_cmd, req.command, req.cwd, req.timeout)


@app.post("/build")
async def build():
    """Run make build in the project directory."""
    return await asyncio.to_thread(run_cmd, "make build", str(PROJECT_DIR))


@app.post("/test")
async def test():
    """Run make test in the project directory."""
    return await asyncio.to_thread(run_cmd, "make test", str(PROJECT_DIR), 120)


@app.post("/rpm")
async def rpm():
    """Build all RPMs."""
    return await asyncio.to_thread(run_cmd, "make rpm", str(PROJECT_DIR), 300)


@app.get("/vms")
async def list_vms():
    """List Xen-on-KVM domains via xen-kvm-bridge.sh."""
    if not BRIDGE_SCRIPT.exists():
        raise HTTPException(404, "xen-kvm-bridge.sh not found")
    result = await asyncio.to_thread(
        run_cmd, f"bash {BRIDGE_SCRIPT} list", str(PROJECT_DIR)
    )
    return {"output": result.stdout, "exit_code": result.exit_code}


@app.get("/gpu")
async def list_gpu():
    """List GPU devices available for passthrough."""
    if not BRIDGE_SCRIPT.exists():
        raise HTTPException(404, "xen-kvm-bridge.sh not found")
    result = await asyncio.to_thread(
        run_cmd, f"bash {BRIDGE_SCRIPT} gpu-list", str(PROJECT_DIR)
    )
    return {"output": result.stdout, "exit_code": result.exit_code}


@app.post("/crawl")
async def crawl(req: CrawlRequest):
    """Fetch and extract content from a URL using crawl4ai."""
    try:
        from crawl4ai import AsyncWebCrawler

        async with AsyncWebCrawler() as crawler:
            result = await crawler.arun(url=req.url)
            response = {"url": req.url, "success": result.success}
            if req.extract_text and result.markdown:
                response["text"] = result.markdown[:100000]
            if req.extract_links and result.links:
                response["links"] = result.links.get("internal", [])[:100]
            return response
    except ImportError:
        from urllib.request import urlopen
        try:
            with urlopen(req.url, timeout=30) as resp:
                body = resp.read().decode("utf-8", errors="replace")[:100000]
            return {"url": req.url, "success": True, "text": body}
        except Exception as e:
            return {"url": req.url, "success": False, "error": str(e)}
    except Exception as e:
        return {"url": req.url, "success": False, "error": str(e)}


@app.post("/file/read")
async def read_file(req: FileReadRequest):
    """Read a file from the filesystem."""
    p = Path(req.path).expanduser()
    if not p.exists():
        raise HTTPException(404, f"File not found: {req.path}")
    if not p.is_file():
        raise HTTPException(400, f"Not a file: {req.path}")

    text = p.read_text(errors="replace")
    lines = text.splitlines(keepends=True)

    if req.offset > 0:
        lines = lines[req.offset:]
    if req.limit > 0:
        lines = lines[:req.limit]

    return {"path": str(p), "content": "".join(lines), "total_lines": len(text.splitlines())}


@app.post("/file/write")
async def write_file(req: FileWriteRequest):
    """Write content to a file."""
    p = Path(req.path).expanduser()
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(req.content)
    return {"path": str(p), "bytes_written": len(req.content)}


# ── WebSocket live shell ─────────────────────────────────────────

@app.websocket("/ws/shell")
async def ws_shell(ws: WebSocket):
    """Live interactive shell via WebSocket.

    Send JSON: {"command": "make build"}
    Receive streaming stdout/stderr lines as they appear.
    """
    await ws.accept()
    try:
        while True:
            data = await ws.receive_text()
            msg = json.loads(data)
            cmd = msg.get("command", "")
            cwd = msg.get("cwd", str(PROJECT_DIR))

            proc = await asyncio.create_subprocess_shell(
                cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=cwd,
            )

            async def stream(pipe, stream_name):
                async for line in pipe:
                    await ws.send_json({
                        "stream": stream_name,
                        "line": line.decode("utf-8", errors="replace").rstrip("\n"),
                    })

            await asyncio.gather(
                stream(proc.stdout, "stdout"),
                stream(proc.stderr, "stderr"),
            )

            exit_code = await proc.wait()
            await ws.send_json({"done": True, "exit_code": exit_code})

    except WebSocketDisconnect:
        pass


# ── Entry point ──────────────────────────────────────────────────

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        "agent:app",
        host="0.0.0.0",
        port=8420,
        reload=False,
        log_level="info",
    )
