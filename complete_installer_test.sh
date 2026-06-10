#!/usr/bin/env bash
# Run the golden validation flow locally — same scripts and order as CI.
#
# No hardware (matches golden-no-hw.yml):
#   ./complete_installer_test.sh --no-hw
#
# Hardware (matches golden-hw.yml):
#   sudo ./complete_installer_test.sh
#
# Re-run tests after a previous install:
#   sudo ./complete_installer_test.sh --skip-install
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${REPO_ROOT}/.github/scripts"
GOLDEN_JSON="${GOLDEN_JSON:-${REPO_ROOT}/golden.json}"

MODE=""              # hw | no-hw
SKIP_INSTALL=0
INSTALL_ONLY=0
FORCE_FLASH="${FORCE_FLASH:-0}"
RUNNER_LABEL="${GOLDEN_RUNNER_LABEL:-$(hostname 2>/dev/null || echo unknown)}"
ORIGINAL_ARGS=("$@")

declare -a SUMMARY_NAMES=()
declare -a SUMMARY_RESULTS=()
declare -a SUMMARY_DETAILS=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Run .github/scripts in the same order as CI and print a pass/fail summary.

Scripts (no-hw):  golden-install.sh → verify-versions.sh
Scripts (hw):     golden-install.sh --hw → verify-versions.sh → smi-reset.sh → ttnn-unit-test.sh

Options:
  --hw              Force hardware flow (requires root; needs /dev/tenstorrent for full pass).
  --no-hw           Install + verify only (no device required).
  --skip-install    Skip golden-install.sh; run verification/tests only.
  --install-only    Run golden-install.sh only, then print summary and exit.
  --force-flash     Pass --force-flash to golden-install.sh (default: firmware flash off).
  --runner-label N  Label for ttnn-unit-test.sh logs (default: hostname).
  -h, --help        Show this help.

Environment:
  GOLDEN_JSON           Path to golden.json (default: ./golden.json)
  GOLDEN_RUNNER_LABEL   Same as --runner-label
  VENV_DIR              Installer venv (default: /root/.tenstorrent-venv when root)
  NUM_RESETS            smi-reset.sh count (default: 10)
  FORCE_FLASH           Set to 1 to enable --force-flash (same as flag)
EOF
}

log() {
  printf '%s\n' "$*"
}

banner() {
  printf '\n%s\n' "======================================================================"
  printf '  %s\n' "$1"
  printf '%s\n\n' "======================================================================"
}

record_result() {
  SUMMARY_NAMES+=("$1")
  SUMMARY_RESULTS+=("$2")
  SUMMARY_DETAILS+=("${3:-}")
}

detect_mode() {
  if [[ -n "${MODE}" ]]; then
    return 0
  fi
  if [[ -e /dev/tenstorrent ]]; then
    MODE=hw
  else
    MODE=no-hw
  fi
}

resolve_venv_dir() {
  if [[ -n "${VENV_DIR:-}" ]]; then
    export VENV_DIR
    return 0
  fi
  if [[ "${EUID}" -eq 0 ]]; then
    VENV_DIR=/root/.tenstorrent-venv
  else
    VENV_DIR="${HOME}/.tenstorrent-venv"
  fi
  export VENV_DIR
}

run_script() {
  local display_name="$1"
  shift

  banner "${display_name}"
  local start_ts end_ts elapsed rc
  start_ts="$(date +%s)"
  set +e
  "$@"
  rc=$?
  set -e
  end_ts="$(date +%s)"
  elapsed=$((end_ts - start_ts))

  if [[ "${rc}" -eq 0 ]]; then
    record_result "${display_name}" PASS "exit 0 (${elapsed}s)"
    log ">>> ${display_name}: PASS (${elapsed}s)"
    return 0
  fi
  record_result "${display_name}" FAIL "exit ${rc} (${elapsed}s)"
  log ">>> ${display_name}: FAIL (exit ${rc}, ${elapsed}s)"
  return "${rc}"
}

record_skip() {
  local name="$1" reason="$2"
  banner "${name} (skipped)"
  log "SKIP: ${reason}"
  record_result "${name}" SKIP "${reason}"
}

print_summary() {
  local pass=0 fail=0 skip=0 i
  banner "Summary"
  printf '%-40s %-6s %s\n' "STEP" "RESULT" "DETAIL"
  printf '%s\n' "---------------------------------------- ------ ------------------------------"
  for i in "${!SUMMARY_NAMES[@]}"; do
    printf '%-40s %-6s %s\n' \
      "${SUMMARY_NAMES[$i]}" "${SUMMARY_RESULTS[$i]}" "${SUMMARY_DETAILS[$i]}"
    case "${SUMMARY_RESULTS[$i]}" in
      PASS) pass=$((pass + 1)) ;;
      FAIL) fail=$((fail + 1)) ;;
      SKIP) skip=$((skip + 1)) ;;
    esac
  done
  printf '\n'
  log "Totals: ${pass} passed, ${fail} failed, ${skip} skipped (of ${#SUMMARY_NAMES[@]} steps)"
  if [[ "${fail}" -gt 0 ]]; then
    log "Overall: FAIL"
    return 1
  fi
  log "Overall: PASS"
  return 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hw) MODE=hw; shift ;;
    --no-hw) MODE=no-hw; shift ;;
    --skip-install) SKIP_INSTALL=1; shift ;;
    --install-only) INSTALL_ONLY=1; shift ;;
    --force-flash) FORCE_FLASH=1; shift ;;
    --runner-label) RUNNER_LABEL="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -f "${GOLDEN_JSON}" ]]; then
  echo "golden.json not found at ${GOLDEN_JSON}" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required (e.g. apt install jq)" >&2
  exit 1
fi

detect_mode

if [[ "${MODE}" == hw && "${EUID}" -ne 0 ]]; then
  log "Re-execing as root for hardware install/tests (sudo)..."
  exec sudo -E \
    GOLDEN_JSON="${GOLDEN_JSON}" \
    GOLDEN_RUNNER_LABEL="${RUNNER_LABEL}" \
    VENV_DIR="${VENV_DIR:-}" \
    NUM_RESETS="${NUM_RESETS:-}" \
    FORCE_FLASH="${FORCE_FLASH}" \
    bash "${REPO_ROOT}/complete_installer_test.sh" "${ORIGINAL_ARGS[@]}"
fi

resolve_venv_dir
export GOLDEN_JSON

banner "Golden installer test run"
log "Repo:         ${REPO_ROOT}"
log "golden.json:  ${GOLDEN_JSON}"
log "Mode:         ${MODE}"
log "Skip install: ${SKIP_INSTALL}"
log "Install only: ${INSTALL_ONLY}"
log "Force flash:  ${FORCE_FLASH}"
log "Venv:         ${VENV_DIR}"
if [[ "${MODE}" == hw ]]; then
  log "Runner label: ${RUNNER_LABEL}"
  if [[ ! -e /dev/tenstorrent ]]; then
    log "WARNING: /dev/tenstorrent not found; smi-reset and ttnn-unit-test may fail." >&2
  fi
fi

# --- golden-install.sh ---
if [[ "${SKIP_INSTALL}" -eq 0 ]]; then
  install_args=()
  if [[ "${MODE}" == hw ]]; then
    install_args+=(--hw)
  fi
  if [[ "${FORCE_FLASH}" -eq 1 ]]; then
    install_args+=(--force-flash)
  fi
  run_script "golden-install.sh" \
    env GOLDEN_JSON="${GOLDEN_JSON}" bash "${SCRIPTS_DIR}/golden-install.sh" "${install_args[@]}" || true
else
  record_skip "golden-install.sh" "--skip-install"
fi

if [[ "${INSTALL_ONLY}" -eq 1 ]]; then
  print_summary
  exit $?
fi

# --- verify-versions.sh ---
run_script "verify-versions.sh" \
  env GOLDEN_JSON="${GOLDEN_JSON}" VENV_DIR="${VENV_DIR}" bash "${SCRIPTS_DIR}/verify-versions.sh" || true

if [[ "${MODE}" == hw ]]; then
  # --- smi-reset.sh ---
  run_script "smi-reset.sh" \
    env VENV_DIR="${VENV_DIR}" NUM_RESETS="${NUM_RESETS:-10}" bash "${SCRIPTS_DIR}/smi-reset.sh" || true

  # --- ttnn-unit-test.sh ---
  run_script "ttnn-unit-test.sh" \
    env \
      GOLDEN_JSON="${GOLDEN_JSON}" \
      GOLDEN_RUNNER_LABEL="${RUNNER_LABEL}" \
      GITHUB_RUNNER_NAME="${RUNNER_LABEL}" \
      bash "${SCRIPTS_DIR}/ttnn-unit-test.sh" || true
fi

print_summary
