#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2025-2026 Tenstorrent AI ULC
# SPDX-License-Identifier: Apache-2.0
#
# Offline golden-manifest test — same order as CI hardware jobs, on your machine.
#
#   sudo ./offline_manifest_test.sh --hw p150a
#   sudo ./offline_manifest_test.sh --hw wh-6u
#   ./offline_manifest_test.sh --no-hw
#   sudo ./offline_manifest_test.sh --hw bh-galaxy --skip-install
#
# Log (always created, even on crash): logs/offline_manifest_test-<timestamp>.log
set -uo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Paths and defaults
# ──────────────────────────────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${REPO_ROOT}/.github/scripts"
GOLDEN_JSON="${GOLDEN_JSON:-${REPO_ROOT}/golden.json}"
HF_MODELS_HOST="${HF_MODELS_HOST:-/opt/tenstorrent/hf-models}"

MODE=""                  # hw | no-hw
HW_TYPE=""               # normalized board id (p150a, wh-6u, ...)
SKIP_INSTALL=0
INSTALL_ONLY=0
FORCE_FLASH="${FORCE_FLASH:-1}"
NUM_RESETS="${NUM_RESETS:-10}"
RUNNER_LABEL="${GOLDEN_RUNNER_LABEL:-}"
ENABLE_LOG="${OFFLINE_MANIFEST_LOG_ENABLE:-1}"
LOG_FILE="${OFFLINE_MANIFEST_LOG:-}"
USE_COLOR=0
ORIGINAL_ARGS=("$@")

# Filled by apply_board_profile
SMI_RESET_MODE=""
METAL_KIND=""            # bh | wh6u | none
WEIGHTS_REQUIRED=0
WEIGHTS_NAME=""
declare -a WEIGHTS_CANDIDATES=()

WH_6U_IMAGE_REPO="${WH_6U_IMAGE_REPO:-ghcr.io/tenstorrent/tt-metal/upstream-tests-wh-6u}"
METAL_UPSTREAM_TIMEOUT="${METAL_UPSTREAM_TIMEOUT:-120m}"

declare -a SUMMARY_NAMES=()
declare -a SUMMARY_RESULTS=()
declare -a SUMMARY_DETAILS=()

_SUMMARY_PRINTED=0
_EXITING=0
_INTERRUPTED=0
_TEE_ACTIVE=0

# ──────────────────────────────────────────────────────────────────────────────
# Colors (captured before stdout is redirected to tee)
# ──────────────────────────────────────────────────────────────────────────────

init_color() {
  if [[ "${NO_COLOR:-}" == 1 || "${TERM:-}" == "dumb" ]]; then
    USE_COLOR=0
  elif [[ -t 1 ]]; then
    USE_COLOR=1
  fi
  if [[ "${USE_COLOR}" -eq 1 ]]; then
    C_RST=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[31m'
    C_GRN=$'\033[32m'
    C_YEL=$'\033[33m'
    C_CYN=$'\033[36m'
  else
    C_RST="" C_BOLD="" C_DIM="" C_RED="" C_GRN="" C_YEL="" C_CYN=""
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Help
# ──────────────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
${C_BOLD}Usage:${C_RST} $(basename "$0") --hw TYPE [OPTIONS]
       $(basename "$0") --no-hw [OPTIONS]

Run the golden.json install + validation flow offline — the same scripts and
order as CI hardware jobs (install, flash, verify, reset ×10, snapshot, metal
upstream). No ttnn unit test.

${C_BOLD}Hardware (--hw TYPE)${C_RST}

  TYPE         reset    metal image                 weights
  ----------   ------   -------------------------   ------------------------------
  p100a        pci      upstream-tests-bh           Llama-3.1-8B-Instruct
  p150a        pci      upstream-tests-bh           Llama-3.1-8B-Instruct
  p300a        pci      upstream-tests-bh-p300      Llama-3.1-8B-Instruct
  quietbox2    pci      upstream-tests-bh-qb-ge     Llama-3.1-8B-Instruct
  loudbox      pci      upstream-tests-bh           Llama-3.3-70B-Instruct
  bh-galaxy    glx      upstream-tests-bh-glx       Llama-3.1-8B-Instruct
  wh-6u        glx      upstream-tests-wh-6u        Llama-3.1-8B-Instruct

  Aliases: p100, p150, p300, qb, quietbox, galaxy, glx, 6u, wh_6u

${C_BOLD}Options${C_RST}
  --hw TYPE         Hardware flow for TYPE (required for device tests).
  --no-hw           Install + verify only (no device required).
  --skip-install    Skip golden-install.sh; run verification / tests only.
  --install-only    Run golden-install.sh only, then print summary and exit.
  --force-flash     Flash firmware (default: on for --hw, matching CI).
  --no-force-flash  Skip firmware flash.
  --runner-label N  Override the label passed to install / reset / metal.
  --log FILE        Log path (default: logs/offline_manifest_test-<ts>.log).
  --no-log          Do not tee output to a log file.
  --no-color        Disable ANSI colors.
  -h, --help        Show this help.

${C_BOLD}Environment${C_RST}
  GOLDEN_JSON              Path to golden.json (default: ./golden.json)
  VENV_DIR                 Installer venv (auto-detected after install)
  NUM_RESETS               smi-reset.sh count (default: 10)
  FORCE_FLASH              1 (default for --hw) force-flash; 0 skip
  HF_MODELS_HOST           Weight root (default: /opt/tenstorrent/hf-models)
  LLAMA_DIR                Override 8B Instruct path (WH 6U / boards that need it)
  OFFLINE_MANIFEST_LOG     Same as --log
  METAL_UPSTREAM_TIMEOUT   timeout(1) for WH 6U metal suite (default: 120m)

Missing model weights print a large warning and are recorded as WARN. Install,
flash, reset, and snapshot still run.
EOF
}

# ──────────────────────────────────────────────────────────────────────────────
# Logging — file is created before any work so a crash still leaves a log
# ──────────────────────────────────────────────────────────────────────────────

log()  { printf '%s\n' "$*"; }
dim()  { printf '%s%s%s\n' "${C_DIM}" "$*" "${C_RST}"; }

paint_result() {
  local result="$1"
  case "${result}" in
    PASS) printf '%s%s%s' "${C_GRN}" "${result}" "${C_RST}" ;;
    FAIL) printf '%s%s%s' "${C_RED}" "${result}" "${C_RST}" ;;
    WARN) printf '%s%s%s' "${C_YEL}" "${result}" "${C_RST}" ;;
    SKIP) printf '%s%s%s' "${C_DIM}" "${result}" "${C_RST}" ;;
    *)    printf '%s' "${result}" ;;
  esac
}

banner() {
  printf '\n%s%s%s\n' "${C_CYN}" "======================================================================" "${C_RST}"
  printf '%s  %s%s\n' "${C_BOLD}" "$1" "${C_RST}"
  printf '%s%s%s\n\n' "${C_CYN}" "======================================================================" "${C_RST}"
}

write_log_header() {
  local dest="$1"
  {
    echo "======================================================================"
    echo "  offline_manifest_test"
    echo "  started: $(date -Is 2>/dev/null || date)"
    echo "  host:    $(hostname 2>/dev/null || echo unknown)"
    echo "  user:    $(id -un 2>/dev/null || echo unknown)  euid=${EUID}"
    echo "  argv:    ${ORIGINAL_ARGS[*]}"
    echo "  cwd:     $(pwd)"
    echo "======================================================================"
    echo
  } >>"${dest}"
}

write_log_footer() {
  local rc="${1:-0}"
  local dest="${LOG_FILE:-}"
  [[ -n "${dest}" && -e "${dest}" ]] || return 0
  {
    echo
    echo "======================================================================"
    echo "  ended:   $(date -Is 2>/dev/null || date)"
    echo "  exit:    ${rc}"
    echo "  log:     ${dest}"
    echo "======================================================================"
  } >>"${dest}"
}

setup_logging() {
  [[ "${ENABLE_LOG}" -eq 1 ]] || return 0
  [[ "${_TEE_ACTIVE}" -eq 1 ]] && return 0

  if [[ -z "${LOG_FILE}" ]]; then
    LOG_FILE="${REPO_ROOT}/logs/offline_manifest_test-$(date +%Y%m%d-%H%M%S).log"
  fi

  # Absolute path so a later sudo re-exec / cd cannot lose the file.
  mkdir -p "$(dirname "${LOG_FILE}")"
  if [[ "${LOG_FILE}" != /* ]]; then
    LOG_FILE="$(cd "$(dirname "${LOG_FILE}")" && pwd)/$(basename "${LOG_FILE}")"
  fi

  # Create + header first. This file exists even if tee or the rest never starts.
  if [[ ! -e "${LOG_FILE}" ]]; then
    : >"${LOG_FILE}"
    write_log_header "${LOG_FILE}"
  fi
  chmod a+rw "${LOG_FILE}" 2>/dev/null || chmod a+r "${LOG_FILE}" 2>/dev/null || true

  export OFFLINE_MANIFEST_LOG="${LOG_FILE}"
  _TEE_ACTIVE=1

  if command -v stdbuf >/dev/null 2>&1; then
    exec > >(stdbuf -oL -eL tee -a "${LOG_FILE}") 2>&1
  else
    exec > >(tee -a "${LOG_FILE}") 2>&1
  fi
}

on_exit() {
  local rc=$?
  [[ "${_EXITING}" -eq 1 ]] && return 0
  _EXITING=1
  trap - EXIT INT TERM

  if [[ "${_SUMMARY_PRINTED}" -eq 0 ]]; then
    if [[ "${_INTERRUPTED}" -eq 1 ]]; then
      record_result "run" FAIL "interrupted"
    elif [[ "${rc}" -ne 0 ]]; then
      record_result "run" FAIL "aborted (exit ${rc})"
    fi
    print_summary || true
  fi

  # Let tee drain, then stamp the file directly (survives a dead tee).
  sleep 0.2 2>/dev/null || true
  write_log_footer "${rc}"
  if [[ -n "${LOG_FILE:-}" && -e "${LOG_FILE}" ]]; then
    chmod a+r "${LOG_FILE}" 2>/dev/null || true
  fi
}

on_signal() {
  local sig="$1"
  _INTERRUPTED=1
  echo
  log "${C_YEL}Caught ${sig} — writing summary and exiting.${C_RST}"
  exit 130
}

install_traps() {
  trap on_exit EXIT
  trap 'on_signal INT' INT
  trap 'on_signal TERM' TERM
}

# ──────────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────────

record_result() {
  SUMMARY_NAMES+=("$1")
  SUMMARY_RESULTS+=("$2")
  SUMMARY_DETAILS+=("${3:-}")
}

record_skip() {
  local name="$1" reason="$2"
  banner "${name} (skipped)"
  log "${C_DIM}SKIP: ${reason}${C_RST}"
  record_result "${name}" SKIP "${reason}"
}

print_summary() {
  local pass=0 fail=0 warn=0 skip=0 i
  _SUMMARY_PRINTED=1

  banner "Summary"
  printf '%-42s %-6s %s\n' "STEP" "RESULT" "DETAIL"
  printf '%s\n' "------------------------------------------ ------ ------------------------------"
  if [[ ${#SUMMARY_NAMES[@]} -gt 0 ]]; then
    for i in "${!SUMMARY_NAMES[@]}"; do
      printf '%-42s ' "${SUMMARY_NAMES[$i]}"
      paint_result "${SUMMARY_RESULTS[$i]}"
      printf '  %s\n' "${SUMMARY_DETAILS[$i]}"
      case "${SUMMARY_RESULTS[$i]}" in
        PASS) pass=$((pass + 1)) ;;
        FAIL) fail=$((fail + 1)) ;;
        WARN) warn=$((warn + 1)) ;;
        SKIP) skip=$((skip + 1)) ;;
      esac
    done
  else
    log "${C_DIM}(no steps recorded)${C_RST}"
  fi

  printf '\n'
  log "Totals: ${pass} passed, ${fail} failed, ${warn} warned, ${skip} skipped (of ${#SUMMARY_NAMES[@]} steps)"
  if [[ -n "${LOG_FILE:-}" ]]; then
    log "Log:    ${LOG_FILE}"
  fi
  if [[ "${fail}" -gt 0 ]]; then
    log "Overall: ${C_RED}${C_BOLD}FAIL${C_RST}"
    return 1
  fi
  if [[ "${warn}" -gt 0 ]]; then
    log "Overall: ${C_YEL}${C_BOLD}PASS (with warnings)${C_RST}"
    return 0
  fi
  log "Overall: ${C_GRN}${C_BOLD}PASS${C_RST}"
  return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Board profiles
# ──────────────────────────────────────────────────────────────────────────────

normalize_hw_type() {
  local raw="${1,,}"
  case "${raw}" in
    p100a | p100)                 printf 'p100a\n' ;;
    p150a | p150)                 printf 'p150a\n' ;;
    p300a | p300)                 printf 'p300a\n' ;;
    quietbox2 | quietbox | qb | qb-ge | qb_ge)
                                  printf 'quietbox2\n' ;;
    loudbox | lb)                 printf 'loudbox\n' ;;
    bh-galaxy | bh_galaxy | galaxy | glx | bh-glx)
                                  printf 'bh-galaxy\n' ;;
    wh-6u | wh_6u | 6u | wormhole-6u | wormhole_6u)
                                  printf 'wh-6u\n' ;;
    *)
      echo "Unknown hardware type: ${1}" >&2
      echo "Use: p100a p150a p300a quietbox2 loudbox bh-galaxy wh-6u" >&2
      return 2
      ;;
  esac
}

apply_board_profile() {
  local board="$1"
  local llama8_instruct="${HF_MODELS_HOST}/meta-llama/Llama-3.1-8B-Instruct"
  local llama8_legacy="${HF_MODELS_HOST}/meta-llama/Llama-3.1-8B"
  local llama70="${HF_MODELS_HOST}/meta-llama/Llama-3.3-70B-Instruct"

  SMI_RESET_MODE=pci
  METAL_KIND=bh
  WEIGHTS_REQUIRED=0
  WEIGHTS_NAME=""
  WEIGHTS_CANDIDATES=()

  case "${board}" in
    p100a | p150a | p300a)
      WEIGHTS_REQUIRED=1
      WEIGHTS_NAME="Llama-3.1-8B-Instruct"
      WEIGHTS_CANDIDATES=("${llama8_instruct}" "${llama8_legacy}")
      ;;
    quietbox2 | bh-galaxy)
      WEIGHTS_REQUIRED=1
      WEIGHTS_NAME="Llama-3.1-8B-Instruct"
      WEIGHTS_CANDIDATES=("${llama8_instruct}")
      [[ "${board}" == "bh-galaxy" ]] && SMI_RESET_MODE=glx
      ;;
    loudbox)
      WEIGHTS_REQUIRED=1
      WEIGHTS_NAME="Llama-3.3-70B-Instruct"
      WEIGHTS_CANDIDATES=("${llama70}")
      ;;
    wh-6u)
      SMI_RESET_MODE=glx
      METAL_KIND=wh6u
      WEIGHTS_REQUIRED=1
      WEIGHTS_NAME="Llama-3.1-8B-Instruct"
      WEIGHTS_CANDIDATES=("${llama8_instruct}")
      ;;
  esac

  if [[ "${WEIGHTS_REQUIRED}" -eq 1 && -n "${LLAMA_DIR:-}" ]]; then
    WEIGHTS_CANDIDATES=("${LLAMA_DIR}" "${WEIGHTS_CANDIDATES[@]}")
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────

resolve_venv_dir() {
  local candidate
  if [[ -n "${VENV_DIR:-}" && -x "${VENV_DIR}/bin/tt-smi" ]]; then
    export VENV_DIR
    return 0
  fi
  if [[ -f /tmp/tenstorrent-installer-venv.path ]]; then
    candidate="$(cat /tmp/tenstorrent-installer-venv.path)"
    if [[ -x "${candidate}/bin/tt-smi" ]]; then
      VENV_DIR="${candidate}"
      export VENV_DIR
      return 0
    fi
  fi
  for candidate in "${HOME}/.tenstorrent-venv" /root/.tenstorrent-venv; do
    if [[ -x "${candidate}/bin/tt-smi" ]]; then
      VENV_DIR="${candidate}"
      export VENV_DIR
      return 0
    fi
  done
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
  set +e
  end_ts="$(date +%s)"
  elapsed=$((end_ts - start_ts))

  if [[ "${rc}" -eq 0 ]]; then
    record_result "${display_name}" PASS "exit 0 (${elapsed}s)"
    log "${C_GRN}>>> ${display_name}: PASS (${elapsed}s)${C_RST}"
    return 0
  fi
  record_result "${display_name}" FAIL "exit ${rc} (${elapsed}s)"
  log "${C_RED}>>> ${display_name}: FAIL (exit ${rc}, ${elapsed}s)${C_RST}"
  return "${rc}"
}

normalize_metal_image_tag() {
  local tag="${1:?}"
  case "${tag}" in
    latest-rc | latest) printf '%s\n' "${tag}" ;;
    v*) printf '%s\n' "${tag}" ;;
    *) printf 'v%s\n' "${tag}" ;;
  esac
}

# ──────────────────────────────────────────────────────────────────────────────
# Weights preflight — warn loudly, never abort the rest of the run
# ──────────────────────────────────────────────────────────────────────────────

weights_look_present() {
  local dir="${1:?}"
  [[ -d "${dir}" ]] || return 1
  [[ -f "${dir}/config.json" ]] || [[ -f "${dir}/tokenizer.json" ]]
}

print_weights_warning() {
  local board="$1"
  printf '\n%s' "${C_YEL}${C_BOLD}"
  cat <<EOF
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!!
!!  WARNING: metal-upstream weights are MISSING
!!
!!  Board:     ${board}
!!  Expected:  ${WEIGHTS_NAME}
!!  Looked in:
EOF
  local p
  for p in "${WEIGHTS_CANDIDATES[@]}"; do
    echo "!!             ${p}"
  done
  cat <<EOF
!!
!!  A real HF snapshot needs config.json or tokenizer.json.
!!
!!  Install, firmware flash, and reset ×${NUM_RESETS} will still run.
!!  Metal upstream will almost certainly FAIL until weights are present.
!!
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
EOF
  printf '%s\n\n' "${C_RST}"
}

check_weights() {
  banner "Weights preflight"

  if [[ "${WEIGHTS_REQUIRED}" -eq 0 ]]; then
    log "Board ${HW_TYPE} does not need host model weights for metal upstream."
    record_result "weights preflight" SKIP "${WEIGHTS_NAME}"
    return 0
  fi

  local found="" p
  for p in "${WEIGHTS_CANDIDATES[@]}"; do
    log "Checking ${p}"
    if weights_look_present "${p}"; then
      found="${p}"
      break
    fi
    if [[ -d "${p}" ]]; then
      dim "  directory exists but has no config.json / tokenizer.json"
    else
      dim "  not found"
    fi
  done

  if [[ -n "${found}" ]]; then
    log "${C_GRN}Weights OK:${C_RST} ${found}"
    # WH 6U metal step mounts LLAMA_DIR; keep it pointing at the tree we found.
    if [[ "${METAL_KIND}" == "wh6u" ]]; then
      LLAMA_DIR="${found}"
      export LLAMA_DIR
    fi
    record_result "weights preflight" PASS "${found}"
    return 0
  fi

  print_weights_warning "${HW_TYPE}"
  record_result "weights preflight" WARN "missing ${WEIGHTS_NAME}"
  return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# apt-get update preflight (stale Kitware key blocks tt-installer)
# ──────────────────────────────────────────────────────────────────────────────

refresh_kitware_apt_key() {
  local keyring="/usr/share/keyrings/kitware-archive-keyring.gpg"
  local tmp
  tmp="$(mktemp)"
  if ! curl -fsSL https://apt.kitware.com/keys/kitware-archive-latest.asc \
      | gpg --dearmor >"${tmp}"; then
    rm -f "${tmp}"
    echo "WARNING: could not download Kitware apt key" >&2
    return 1
  fi
  install -m 0644 "${tmp}" "${keyring}"
  rm -f "${tmp}"
  log "Updated ${keyring}"
}

disable_kitware_apt_repo() {
  local src="/etc/apt/sources.list.d/kitware.list"
  if [[ -f "${src}" ]]; then
    mv "${src}" "${src}.disabled"
    log "Disabled ${src} (stale/unsigned Kitware repo was blocking apt-get update)"
  fi
}

ensure_apt_update() {
  local out rc
  out="$(mktemp)"
  set +e
  apt-get update >"${out}" 2>&1
  rc=$?
  set +e
  cat "${out}"

  if [[ "${rc}" -eq 0 ]]; then
    rm -f "${out}"
    log "apt-get update: ok"
    return 0
  fi

  if grep -Eq 'kitware|NO_PUBKEY 65ADECD7A7039392' "${out}"; then
    log "Kitware apt repo is unsigned / missing key; refreshing keyring"
    refresh_kitware_apt_key || true
    set +e
    apt-get update >"${out}" 2>&1
    rc=$?
    set +e
    cat "${out}"
  fi

  if [[ "${rc}" -ne 0 ]] && grep -Eq 'kitware|NO_PUBKEY 65ADECD7A7039392' "${out}"; then
    log "Kitware repo still broken after key refresh; disabling it so installer can proceed"
    disable_kitware_apt_repo
    set +e
    apt-get update >"${out}" 2>&1
    rc=$?
    set +e
    cat "${out}"
  fi

  rm -f "${out}"
  if [[ "${rc}" -ne 0 ]]; then
    echo "FAIL: apt-get update still failing (exit ${rc})" >&2
    return "${rc}"
  fi
  log "apt-get update: ok"
}

# ──────────────────────────────────────────────────────────────────────────────
# WH 6U metal upstream (image default target; not the BH metal-upstream.sh path)
# ──────────────────────────────────────────────────────────────────────────────

run_wh_6u_metal_upstream() {
  local metal_tag image llama_dir
  metal_tag="$(jq -r '.["metal-upstream-tag"] // .["metal-version"] // empty' "${GOLDEN_JSON}")"
  if [[ -z "${metal_tag}" ]]; then
    echo "FAIL: golden.json has no metal-version / metal-upstream-tag" >&2
    return 1
  fi
  image="${WH_6U_IMAGE_REPO}:$(normalize_metal_image_tag "${metal_tag}")"
  llama_dir="${LLAMA_DIR:-${HF_MODELS_HOST}/meta-llama/Llama-3.1-8B-Instruct}"

  if [[ ! -d /dev/hugepages-1G ]]; then
    echo "FAIL: /dev/hugepages-1G is missing" >&2
    return 1
  fi
  if [[ ! -e /dev/tenstorrent ]]; then
    echo "FAIL: /dev/tenstorrent is missing" >&2
    return 1
  fi
  if ! weights_look_present "${llama_dir}"; then
    echo "FAIL: weights missing at ${llama_dir}" >&2
    return 1
  fi

  echo "golden.json pins:"
  jq -r '
    "  installer:     \(.installer)",
    "  kmd:           \(.kmd)",
    "  smi:           \(.smi)",
    "  flash:         \(.flash)",
    "  firmware:      \(.firmware)",
    "  metal-version: \(.["metal-version"] // "n/a")"
  ' "${GOLDEN_JSON}"
  echo "running:"
  echo "  image:     ${image}"
  echo "  target:    wh_6u (image default)"
  echo "  LLAMA_DIR: ${llama_dir}"
  echo "  timeout:   ${METAL_UPSTREAM_TIMEOUT}"

  docker pull "${image}"

  local -a device_args=(--device /dev/tenstorrent)
  if [[ -e /dev/ipmi0 ]]; then
    device_args+=(--device /dev/ipmi0)
  fi

  # Do not run tt-smi / Luwen tools while this container is up.
  timeout --preserve-status "${METAL_UPSTREAM_TIMEOUT}" docker run --rm \
    -v /dev/hugepages-1G:/dev/hugepages-1G \
    "${device_args[@]}" \
    -v "${llama_dir}:${llama_dir}" \
    -e HF_MODEL="${llama_dir}" \
    -e TT_CACHE_PATH="${llama_dir}" \
    "${image}"
}

# ──────────────────────────────────────────────────────────────────────────────
# Args
# ──────────────────────────────────────────────────────────────────────────────

init_color

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hw)
      if [[ -z "${2:-}" || "${2}" == -* ]]; then
        echo "error: --hw requires a board type (e.g. --hw p150a)" >&2
        usage >&2
        exit 2
      fi
      MODE=hw
      HW_TYPE="$(normalize_hw_type "$2")" || exit 2
      shift 2
      ;;
    --no-hw)
      MODE=no-hw
      HW_TYPE=""
      shift
      ;;
    --skip-install) SKIP_INSTALL=1; shift ;;
    --install-only) INSTALL_ONLY=1; shift ;;
    --force-flash) FORCE_FLASH=1; shift ;;
    --no-force-flash) FORCE_FLASH=0; shift ;;
    --runner-label)
      [[ -n "${2:-}" && "${2}" != -* ]] || { echo "error: --runner-label needs a value" >&2; exit 2; }
      RUNNER_LABEL="$2"
      shift 2
      ;;
    --log)
      [[ -n "${2:-}" && "${2}" != -* ]] || { echo "error: --log needs a file path" >&2; exit 2; }
      LOG_FILE="$2"
      ENABLE_LOG=1
      shift 2
      ;;
    --no-log) ENABLE_LOG=0; LOG_FILE=""; shift ;;
    --no-color) NO_COLOR=1; init_color; shift ;;
    -h | --help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${MODE}" ]]; then
  echo "error: choose a flow — --hw TYPE  or  --no-hw" >&2
  echo >&2
  usage >&2
  exit 2
fi

if [[ "${MODE}" == hw ]]; then
  apply_board_profile "${HW_TYPE}"
  RUNNER_LABEL="${RUNNER_LABEL:-${HW_TYPE}}"
  # no-hw never flashes; hw matches CI (force-flash) unless --no-force-flash.
fi

# ──────────────────────────────────────────────────────────────────────────────
# Start of run — log file exists from this point on
# ──────────────────────────────────────────────────────────────────────────────

setup_logging
install_traps

if [[ ! -f "${GOLDEN_JSON}" ]]; then
  echo "golden.json not found at ${GOLDEN_JSON}" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required (e.g. apt install jq)" >&2
  exit 1
fi

if [[ "${MODE}" == hw && "${EUID}" -ne 0 ]]; then
  log "Re-execing as root for hardware install/tests (sudo)..."
  exec sudo -E \
    GOLDEN_JSON="${GOLDEN_JSON}" \
    GOLDEN_RUNNER_LABEL="${RUNNER_LABEL}" \
    VENV_DIR="${VENV_DIR:-}" \
    NUM_RESETS="${NUM_RESETS}" \
    FORCE_FLASH="${FORCE_FLASH}" \
    HF_MODELS_HOST="${HF_MODELS_HOST}" \
    LLAMA_DIR="${LLAMA_DIR:-}" \
    OFFLINE_MANIFEST_LOG="${LOG_FILE:-}" \
    OFFLINE_MANIFEST_LOG_ENABLE="${ENABLE_LOG}" \
    METAL_UPSTREAM_TIMEOUT="${METAL_UPSTREAM_TIMEOUT}" \
    WH_6U_IMAGE_REPO="${WH_6U_IMAGE_REPO}" \
    NO_COLOR="${NO_COLOR:-}" \
    bash "${REPO_ROOT}/offline_manifest_test.sh" "${ORIGINAL_ARGS[@]}" \
    || exit $?
fi

resolve_venv_dir
export GOLDEN_JSON
if [[ "${MODE}" == hw ]]; then
  export GOLDEN_RUNNER_LABEL="${RUNNER_LABEL}"
  export GITHUB_RUNNER_NAME="${RUNNER_LABEL}"
  export SMI_RESET_MODE="${SMI_RESET_MODE}"
  # HW install uses --no-install-sfpi; skip so a stale host sfpi does not fail verify.
  export SKIP_SFPI_VERSION_CHECK="${SKIP_SFPI_VERSION_CHECK:-1}"
fi

banner "Offline manifest test"
log "Repo:          ${REPO_ROOT}"
log "golden.json:   ${GOLDEN_JSON}"
log "Mode:          ${MODE}${HW_TYPE:+ (${HW_TYPE})}"
log "Skip install:  ${SKIP_INSTALL}"
log "Install only:  ${INSTALL_ONLY}"
if [[ "${MODE}" == hw ]]; then
  log "Force flash:   ${FORCE_FLASH}"
else
  log "Force flash:   n/a"
fi
log "Venv:          ${VENV_DIR}"
if [[ "${MODE}" == hw ]]; then
  log "Runner label:  ${RUNNER_LABEL}"
  log "Reset mode:    ${SMI_RESET_MODE}  (×${NUM_RESETS})"
  log "Metal:         ${METAL_KIND}"
  log "Weights:       ${WEIGHTS_NAME}"
fi
if [[ -n "${LOG_FILE:-}" ]]; then
  log "Log file:      ${LOG_FILE}"
fi
if [[ "${MODE}" == hw && ! -e /dev/tenstorrent ]]; then
  log "${C_YEL}WARNING: /dev/tenstorrent not found; reset and metal upstream may fail.${C_RST}"
fi
jq -r '
  "Pins: kmd=\(.kmd) smi=\(.smi) flash=\(.flash) firmware=\(.firmware) metal=\(.["metal-version"] // "n/a") installer=\(.installer)"
' "${GOLDEN_JSON}"

# ──────────────────────────────────────────────────────────────────────────────
# Steps
# ──────────────────────────────────────────────────────────────────────────────

if [[ "${MODE}" == hw ]]; then
  check_weights
fi

if [[ "${SKIP_INSTALL}" -eq 0 ]]; then
  if [[ "${MODE}" == hw && "${EUID}" -eq 0 ]]; then
    run_script "apt-get update (preflight)" ensure_apt_update || true
  fi
  install_args=()
  if [[ "${MODE}" == hw ]]; then
    install_args+=(--hw)
  fi
  if [[ "${FORCE_FLASH}" -eq 1 && "${MODE}" == hw ]]; then
    install_args+=(--force-flash)
  fi
  run_script "golden-install.sh" \
    env \
      GOLDEN_JSON="${GOLDEN_JSON}" \
      GOLDEN_RUNNER_LABEL="${RUNNER_LABEL}" \
      bash "${SCRIPTS_DIR}/golden-install.sh" "${install_args[@]}" || true
  unset VENV_DIR
  resolve_venv_dir
  log "Using installer venv: ${VENV_DIR}"
else
  record_skip "golden-install.sh" "--skip-install"
  resolve_venv_dir
fi

if [[ "${INSTALL_ONLY}" -eq 1 ]]; then
  print_summary
  exit $?
fi

run_script "verify-versions.sh" \
  env GOLDEN_JSON="${GOLDEN_JSON}" VENV_DIR="${VENV_DIR}" \
      SKIP_SFPI_VERSION_CHECK="${SKIP_SFPI_VERSION_CHECK:-}" \
      bash "${SCRIPTS_DIR}/verify-versions.sh" || true

if [[ "${MODE}" == hw ]]; then
  run_script "smi-reset.sh" \
    env VENV_DIR="${VENV_DIR}" NUM_RESETS="${NUM_RESETS}" \
        GOLDEN_RUNNER_LABEL="${RUNNER_LABEL}" SMI_RESET_MODE="${SMI_RESET_MODE}" \
        bash "${SCRIPTS_DIR}/smi-reset.sh" || true

  run_script "smi-snapshot.sh" \
    env VENV_DIR="${VENV_DIR}" bash "${SCRIPTS_DIR}/smi-snapshot.sh" || true

  if [[ "${METAL_KIND}" == "wh6u" ]]; then
    run_script "metal-upstream (wh-6u / 8B)" run_wh_6u_metal_upstream || true
  else
    run_script "metal-upstream.sh" \
      env \
        GOLDEN_JSON="${GOLDEN_JSON}" \
        GOLDEN_RUNNER_LABEL="${RUNNER_LABEL}" \
        GITHUB_RUNNER_NAME="${RUNNER_LABEL}" \
        HF_MODELS_HOST="${HF_MODELS_HOST}" \
        bash "${SCRIPTS_DIR}/metal-upstream.sh" || true
  fi
fi

print_summary
exit $?
