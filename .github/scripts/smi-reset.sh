#!/usr/bin/env bash
# Reset stress: run tt-smi reset NUM_RESETS times using the installer venv.
# Default is `tt-smi -r`. Galaxy hosts use `tt-smi -glx_reset`.
#
# Every run is timed. The summary prints min, average, and max across the
# attempts (PT-545).
#
# Every product snapshots NVMe drives and md RAID before each reset and
# compares them after. A dropped drive, degraded array, read-only mount, or
# new NVMe/RAID/PCIe-drop line in dmesg fails the run. Disable with
# NVME_RESET_CHECK=0. Artifacts go to NVME_CHECK_ROOT.
#
# Override with:
#   SMI_RESET_MODE=pci|glx
#   SMI_RESET_ARGS='-glx_reset'   # raw args after tt-smi (wins over MODE)
# Or set GOLDEN_RUNNER_LABEL / GITHUB_RUNNER_NAME to a galaxy label (bh-galaxy*).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GOLDEN_JSON="${GOLDEN_JSON:-${REPO_ROOT}/golden.json}"
NUM_RESETS="${NUM_RESETS:-10}"
RUNNER_LABEL="${GOLDEN_RUNNER_LABEL:-${GITHUB_RUNNER_NAME:-}}"

_resolve_installer_venv_dir() {
  if [[ -n "${VENV_DIR:-}" ]]; then
    printf '%s\n' "${VENV_DIR}"
    return 0
  fi
  if [[ -f /tmp/tenstorrent-installer-venv.path ]]; then
    cat /tmp/tenstorrent-installer-venv.path
    return 0
  fi
  if [[ "${EUID}" -eq 0 && -f /root/.tenstorrent-venv/bin/tt-smi ]]; then
    printf '%s\n' /root/.tenstorrent-venv
    return 0
  fi
  printf '%s\n' "${HOME}/.tenstorrent-venv"
}

resolve_reset_args() {
  # Explicit args win (e.g. SMI_RESET_ARGS='-glx_reset').
  if [[ -n "${SMI_RESET_ARGS:-}" ]]; then
    printf '%s\n' "${SMI_RESET_ARGS}"
    return 0
  fi

  local mode="${SMI_RESET_MODE:-}"
  if [[ -z "${mode}" ]]; then
    case "${RUNNER_LABEL}" in
      bh-galaxy* | *-bh-galaxy* | *galaxy*) mode=glx ;;
      *) mode=pci ;;
    esac
  fi

  case "${mode}" in
    glx | galaxy | galaxy_6u)
      printf '%s\n' "-glx_reset"
      ;;
    pci | r | default)
      printf '%s\n' "-r"
      ;;
    *)
      echo "FAIL: unknown SMI_RESET_MODE='${mode}' (use pci or glx)." >&2
      return 1
      ;;
  esac
}

VENV_DIR="$(_resolve_installer_venv_dir)"
if [[ ! -x "${VENV_DIR}/bin/tt-smi" ]]; then
  echo "Installer venv not found at ${VENV_DIR}" >&2
  exit 1
fi
export VENV_DIR
export PATH="${VENV_DIR}/bin:${PATH}"

RESET_ARGS="$(resolve_reset_args)"
# shellcheck disable=SC2206
RESET_ARGV=( ${RESET_ARGS} )
RESET_LABEL="tt-smi ${RESET_ARGS}"

printf '\n========== Reset test (%s) ==========\n' "${RESET_LABEL}"
if [[ -f "${GOLDEN_JSON}" ]] && command -v jq >/dev/null 2>&1; then
  echo "golden.json pins:"
  jq -r '
    "  installer:     \(.installer)",
    "  kmd:           \(.kmd)",
    "  smi:           \(.smi)",
    "  flash:         \(.flash)",
    "  firmware:      \(.firmware)"
  ' "${GOLDEN_JSON}"
fi
NVME_HEALTH="${SCRIPT_DIR}/nvme-health.sh"
NVME_CHECK_ROOT="${NVME_CHECK_ROOT:-${GITHUB_WORKSPACE:-/tmp}/nvme-reset-check}"

want_nvme_check() {
  case "${NVME_RESET_CHECK:-auto}" in
    0 | false | no | off) return 1 ;;
    *) return 0 ;;
  esac
}

format_ms() {
  awk -v ms="$1" 'BEGIN { printf "%.1f", ms / 1000 }'
}

print_timing_summary() {
  local file="$1"
  [[ -s "${file}" ]] || return 0
  awk -v total="${NUM_RESETS}" '
    NR == 1 { min = $1; max = $1 }
    { sum += $1; n++; if ($1 < min) min = $1; if ($1 > max) max = $1 }
    END {
      printf "Reset timing over %d/%d runs: min %.1fs  avg %.1fs  max %.1fs\n",
        n, total, min / 1000, sum / n / 1000, max / 1000
    }
  ' "${file}"
}

NVME_CHECK=0
if want_nvme_check; then
  NVME_CHECK=1
fi

echo "running:"
echo "  command: ${RESET_LABEL} (×${NUM_RESETS})"
echo "  mode:    ${SMI_RESET_MODE:-auto}"
echo "  runner:  ${RUNNER_LABEL:-n/a}"
echo "  nvme:    $([[ "${NVME_CHECK}" -eq 1 ]] && printf 'on' || printf 'off')"
echo "  tt-smi:  $(tt-smi -v 2>&1 | head -n1)"
echo "  venv:    ${VENV_DIR}"
echo ""

TIMING_FILE="${NVME_CHECK_ROOT}/reset-times-ms.txt"
mkdir -p "${NVME_CHECK_ROOT}"
: > "${TIMING_FILE}"

for ((attempt = 1; attempt <= NUM_RESETS; attempt++)); do
  echo "--- ${RESET_LABEL} (${attempt}/${NUM_RESETS}) ---"
  attempt_dir=""
  if [[ "${NVME_CHECK}" -eq 1 ]]; then
    attempt_dir="$(printf '%s/attempt-%02d' "${NVME_CHECK_ROOT}" "${attempt}")"
    rm -rf "${attempt_dir}"
    mkdir -p "${attempt_dir}"
    host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'unknown')"
    printf '\n== NVMe reset check ==\n'
    echo "Host: ${host}"
    echo "Results: ${attempt_dir}"
    echo "Reset: ${RESET_LABEL}"
    echo ""
    echo "Snapshot before..."
    bash "${NVME_HEALTH}" snapshot "${attempt_dir}/before"
    printf 'Before: %s\n' "$(bash "${NVME_HEALTH}" summary "${attempt_dir}/before")"
    bash "${NVME_HEALTH}" mark "${attempt_dir}/dmesg-marker"
    echo "Reset running..."
  fi

  start_ms="$(date +%s%3N)"
  set +e
  tt-smi "${RESET_ARGV[@]}"
  reset_rc=$?
  set -e
  end_ms="$(date +%s%3N)"
  elapsed_ms=$((end_ms - start_ms))
  printf '%s\n' "${elapsed_ms}" >> "${TIMING_FILE}"

  nvme_rc=0
  if [[ "${NVME_CHECK}" -eq 1 ]]; then
    echo "Waiting for device discovery..."
    bash "${NVME_HEALTH}" settle "${attempt_dir}/before" "${attempt_dir}/after"
    bash "${NVME_HEALTH}" collect-dmesg \
      "${attempt_dir}/dmesg-marker" "${attempt_dir}/after/dmesg-new"
    echo "Snapshot after..."
    printf 'After:  %s\n' "$(bash "${NVME_HEALTH}" summary "${attempt_dir}/after")"
    chips="$(cat "${attempt_dir}/after/chips")"
    before_chips="$(cat "${attempt_dir}/before/chips")"
    if [[ "${reset_rc}" -eq 0 && "${chips}" == "${before_chips}" ]]; then
      printf 'Reset: exit 0 (All %s chips found in "/dev/tenstorrent")\n' "${chips}"
    else
      printf 'Reset: exit %s (chip count %s, expected %s in "/dev/tenstorrent")\n' \
        "${reset_rc}" "${chips}" "${before_chips}"
    fi
    echo ""
    set +e
    bash "${NVME_HEALTH}" compare "${attempt_dir}/before" "${attempt_dir}/after"
    nvme_rc=$?
    set -e
    echo "Artifacts: ${attempt_dir}"
  fi

  printf 'reset %d/%d: %ss (exit %d)\n' \
    "${attempt}" "${NUM_RESETS}" "$(format_ms "${elapsed_ms}")" "${reset_rc}"

  if [[ "${reset_rc}" -ne 0 ]]; then
    echo "FAIL: reset ${attempt}/${NUM_RESETS} (${RESET_LABEL})"
    print_timing_summary "${TIMING_FILE}"
    exit "${reset_rc}"
  fi
  if [[ "${nvme_rc}" -ne 0 ]]; then
    echo "FAIL: NVMe health check ${attempt}/${NUM_RESETS}"
    print_timing_summary "${TIMING_FILE}"
    exit 1
  fi
  echo "PASS: reset ${attempt}/${NUM_RESETS}"
done

print_timing_summary "${TIMING_FILE}"
echo "PASS: ${NUM_RESETS} consecutive resets succeeded (${RESET_LABEL})"
