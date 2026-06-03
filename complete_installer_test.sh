#!/usr/bin/env bash
# Run the full golden installer validation flow locally (same steps as CI).
# Prints each step to the terminal and prints a pass/fail/skip summary at the end.
#
# Hardware (Tenstorrent device present, run as root):
#   sudo ./complete_installer_test.sh
#   sudo ./complete_installer_test.sh --runner-label tt-ubuntu-2204-p150b-stable
#
# No hardware (install + version verify only):
#   ./complete_installer_test.sh --no-hw
#
# Re-run tests after a previous install (skip tt-installer):
#   sudo ./complete_installer_test.sh --skip-install --runner-label tt-ubuntu-2204-p150b-stable
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${REPO_ROOT}/.github/scripts"
GOLDEN_JSON="${GOLDEN_JSON:-${REPO_ROOT}/golden.json}"
BOARDS_JSON="${REPO_ROOT}/.github/golden-metal-boards.json"

MODE=""          # hw | no-hw
SKIP_INSTALL=0
INSTALL_ONLY=0
RUNNER_LABEL="${GOLDEN_RUNNER_LABEL:-}"
ORIGINAL_ARGS=("$@")

# shellcheck disable=SC2034
declare -a SUMMARY_NAMES=()
declare -a SUMMARY_RESULTS=()
declare -a SUMMARY_DETAILS=()

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options:
  --hw                 Force hardware flow (requires root, /dev/tenstorrent).
  --no-hw              Install + verify only (no device, non-root OK).
  --skip-install       Skip install step; run verification/tests only.
  --install-only       Run install step only, then exit with summary.
  --runner-label NAME  Board profile for metal tests (see .github/golden-metal-boards.json).
                       Required for metal steps unless hostname matches a profile prefix.
  -h, --help           Show this help.

Environment:
  GOLDEN_JSON          Path to golden.json (default: ./golden.json)
  GOLDEN_RUNNER_LABEL  Same as --runner-label
  VENV_DIR             Installer venv (default: /root/.tenstorrent-venv when root, else ~/.tenstorrent-venv)
  NUM_RESETS           tt-smi -r count (default: 10)
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
  local name="$1" result="$2" detail="${3:-}"
  SUMMARY_NAMES+=("${name}")
  SUMMARY_RESULTS+=("${result}")
  SUMMARY_DETAILS+=("${detail}")
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

detect_runner_label() {
  if [[ -n "${RUNNER_LABEL}" ]]; then
    return 0
  fi
  if [[ ! -f "${BOARDS_JSON}" ]] || ! command -v jq >/dev/null 2>&1; then
    return 1
  fi
  local host key prefix
  host="$(hostname 2>/dev/null || echo unknown)"
  while IFS= read -r prefix; do
    [[ -z "${prefix}" ]] && continue
    if [[ "${host}" == "${prefix}" || "${host}" == "${prefix}"* ]]; then
      RUNNER_LABEL="${prefix}"
      log "Auto-selected runner label from hostname: ${RUNNER_LABEL}"
      return 0
    fi
  done < <(jq -r '.[]."runner-label"' "${BOARDS_JSON}")
  return 1
}

resolve_venv_dir() {
  if [[ -n "${VENV_DIR:-}" ]]; then
    return 0
  fi
  if [[ "${EUID}" -eq 0 ]]; then
    VENV_DIR=/root/.tenstorrent-venv
  else
    VENV_DIR="${HOME}/.tenstorrent-venv"
  fi
  export VENV_DIR
}

run_step() {
  local display_name="$1"
  local detail_on_fail="${2:-}"
  shift 2

  banner "${display_name}"
  local start_ts end_ts elapsed rc
  start_ts="$(date +%s)"
  set +e
  "$@"
  rc=$?
  set +e
  end_ts="$(date +%s)"
  elapsed=$((end_ts - start_ts))

  if [[ "${rc}" -eq 0 ]]; then
    record_result "${display_name}" PASS "exit 0 (${elapsed}s)"
    log ">>> ${display_name}: PASS (${elapsed}s)"
    return 0
  fi
  record_result "${display_name}" FAIL "${detail_on_fail:-exit ${rc} (${elapsed}s)}"
  log ">>> ${display_name}: FAIL (exit ${rc}, ${elapsed}s)"
  return "${rc}"
}

should_run_metal_step() {
  local field="$1"
  if [[ "${MODE}" != hw ]]; then
    return 1
  fi
  if [[ -z "${RUNNER_LABEL}" ]]; then
    return 1
  fi
  if [[ ! -f "${BOARDS_JSON}" ]] || ! command -v jq >/dev/null 2>&1; then
    return 1
  fi
  local board enabled
  board="$(
    jq -c --arg key "${RUNNER_LABEL}" '
      [.[]
        | (.["runner-label"] // "") as $prefix
        | select($prefix != "" and ($key == $prefix or ($key | startswith($prefix))))
      ][0]
    ' "${BOARDS_JSON}"
  )"
  if [[ -z "${board}" || "${board}" == "null" ]]; then
    return 1
  fi
  enabled="$(jq -r --arg f "${field}" 'if .[$f] == null then "false" else (.[$f] | tostring) end' <<<"${board}")"
  [[ "${enabled}" == "true" ]]
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
  printf '%-36s %-6s %s\n' "STEP" "RESULT" "DETAIL"
  printf '%s\n' "------------------------------------ ------ ------------------------------"
  for i in "${!SUMMARY_NAMES[@]}"; do
    printf '%-36s %-6s %s\n' \
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
    bash "${REPO_ROOT}/complete_installer_test.sh" "${ORIGINAL_ARGS[@]}"
fi

resolve_venv_dir
export GOLDEN_JSON

banner "Golden installer test run"
log "Repo:          ${REPO_ROOT}"
log "golden.json:   ${GOLDEN_JSON}"
log "Mode:          ${MODE}"
log "Skip install:  ${SKIP_INSTALL}"
log "Install only:  ${INSTALL_ONLY}"
log "Venv:          ${VENV_DIR}"
if [[ "${MODE}" == hw ]]; then
  detect_runner_label || true
  log "Runner label:  ${RUNNER_LABEL:-<unset — metal steps may skip>}"
fi

if [[ "${MODE}" == hw ]]; then
  if [[ ! -e /dev/tenstorrent ]]; then
    log "WARNING: /dev/tenstorrent not found; hardware tests may fail." >&2
  fi
  INSTALL_SCRIPT="${SCRIPTS_DIR}/golden-install-hw.sh"
else
  INSTALL_SCRIPT="${SCRIPTS_DIR}/golden-install.sh"
fi

if [[ "${SKIP_INSTALL}" -eq 0 ]]; then
  run_step "Install (tt-installer)" "" env GOLDEN_JSON="${GOLDEN_JSON}" bash "${INSTALL_SCRIPT}" || true
else
  record_skip "Install (tt-installer)" "--skip-install"
fi

if [[ "${INSTALL_ONLY}" -eq 1 ]]; then
  print_summary
  exit $?
fi

if [[ "${SKIP_INSTALL}" -eq 1 && "${MODE}" == hw ]]; then
  : # verify uses activate-installer-python / venv path files from prior install
fi

run_step "Verify versions" "" \
  env GOLDEN_JSON="${GOLDEN_JSON}" VENV_DIR="${VENV_DIR}" bash "${SCRIPTS_DIR}/verify-golden-versions.sh" || true

if [[ "${MODE}" == hw ]]; then
  run_step "PCI reset stress (tt-smi -r)" "" \
    env VENV_DIR="${VENV_DIR}" NUM_RESETS="${NUM_RESETS:-10}" bash "${SCRIPTS_DIR}/golden-smi-reset-stress.sh" || true

  if should_run_metal_step metal-unit-test; then
    run_step "Metal unit test" "" \
      env \
        GOLDEN_JSON="${GOLDEN_JSON}" \
        GOLDEN_RUNNER_LABEL="${RUNNER_LABEL}" \
        GITHUB_RUNNER_NAME="${RUNNER_LABEL}" \
        bash "${SCRIPTS_DIR}/golden-metal-unit-test.sh" || true
  else
    if [[ -z "${RUNNER_LABEL}" ]]; then
      record_skip "Metal unit test" "set --runner-label (see ${BOARDS_JSON})"
    else
      record_skip "Metal unit test" "disabled for runner label ${RUNNER_LABEL}"
    fi
  fi

  if should_run_metal_step metal-upstream; then
    run_step "Metal upstream tests" "" \
      env \
        GOLDEN_JSON="${GOLDEN_JSON}" \
        GOLDEN_RUNNER_LABEL="${RUNNER_LABEL}" \
        GITHUB_RUNNER_NAME="${RUNNER_LABEL}" \
        bash "${SCRIPTS_DIR}/golden-metal-upstream.sh" || true
  else
    if [[ -z "${RUNNER_LABEL}" ]]; then
      record_skip "Metal upstream tests" "set --runner-label for p150b upstream"
    else
      record_skip "Metal upstream tests" "disabled or no metal-upstream-tag for ${RUNNER_LABEL}"
    fi
  fi
else
  record_skip "PCI reset stress (tt-smi -r)" "--no-hw mode"
  record_skip "Metal unit test" "--no-hw mode"
  record_skip "Metal upstream tests" "--no-hw mode"
fi

print_summary
