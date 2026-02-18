#!/bin/bash
# run-all.sh — Single entry point: setup, test, and validate
#
# This script orchestrates the entire Qubes KVM testing pipeline
# on any KVM-capable Linux machine (EndeavourOS/Arch preferred).
#
# Usage:
#   bash run-all.sh              # Full pipeline: setup → test → report
#   bash run-all.sh setup        # Setup only
#   bash run-all.sh test         # Run E2E tests only
#   bash run-all.sh agent        # Start agent only
#   bash run-all.sh check        # Quick readiness check
#   bash run-all.sh fix          # Fix common issues (glibc, etc.)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_DIR
readonly RESULTS_DIR="${SCRIPT_DIR}/test/results"
readonly TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

log()  { echo ""; echo "==== $* ===="; echo ""; }
info() { echo "[run-all] $*"; }

# ── Phase 1: Setup ───────────────────────────────────────────────

do_setup() {
    log "PHASE 1: Machine Setup"
    bash "$SCRIPT_DIR/setup.sh" full 2>&1 | tee "${RESULTS_DIR}/setup-${TIMESTAMP}.log"
}

# ── Phase 2: E2E Tests ──────────────────────────────────────────

do_test() {
    log "PHASE 2: End-to-End Tests"
    mkdir -p "$RESULTS_DIR"
    bash "$SCRIPT_DIR/test/e2e-kvm-hardware.sh" all 2>&1 | tee "${RESULTS_DIR}/e2e-${TIMESTAMP}.log"
    local exit_code=${PIPESTATUS[0]}

    info "Results saved to: ${RESULTS_DIR}/e2e-${TIMESTAMP}.log"
    return "$exit_code"
}

# ── Phase 3: Agent ───────────────────────────────────────────────

do_agent() {
    log "PHASE 3: Agent Service"
    bash "$SCRIPT_DIR/setup.sh" agent
    info "Agent running at http://$(ip -4 addr show scope global | grep -oP 'inet \K[\d.]+' | head -1):8420"
}

# ── Phase 4: Report ─────────────────────────────────────────────

do_report() {
    log "PIPELINE REPORT"

    local latest_e2e
    latest_e2e="$(ls -t "$RESULTS_DIR"/e2e-*.log 2>/dev/null | head -1 || true)"

    if [[ -n "$latest_e2e" ]]; then
        echo "Latest E2E results:"
        grep -E "PASS|FAIL|SKIP|Summary" "$latest_e2e" 2>/dev/null | tail -20
        echo ""
        local pass fail skip
        pass="$(grep -c '\[PASS\]' "$latest_e2e" 2>/dev/null || echo 0)"
        fail="$(grep -c '\[FAIL\]' "$latest_e2e" 2>/dev/null || echo 0)"
        skip="$(grep -c '\[SKIP\]' "$latest_e2e" 2>/dev/null || echo 0)"
        echo "  PASSED: $pass  FAILED: $fail  SKIPPED: $skip"
    else
        echo "  No test results found. Run: bash run-all.sh test"
    fi

    echo ""
    echo "System status:"
    bash "$SCRIPT_DIR/setup.sh" check 2>/dev/null || true
}

# ── Main ─────────────────────────────────────────────────────────

main() {
    info "Qubes KVM Test Pipeline"
    info "Host: $(hostname) | Kernel: $(uname -r) | $(date)"
    mkdir -p "$RESULTS_DIR"

    case "${1:-full}" in
        setup)  do_setup ;;
        test)   do_test ;;
        agent)  do_agent ;;
        check)  bash "$SCRIPT_DIR/setup.sh" check ;;
        fix)    bash "$SCRIPT_DIR/setup.sh" fix ;;
        report) do_report ;;
        full)
            do_setup
            do_test || true
            do_agent || true
            do_report
            ;;
        *)
            echo "Usage: $(basename "$0") [full|setup|test|agent|check|fix|report]"
            ;;
    esac
}

main "$@"
