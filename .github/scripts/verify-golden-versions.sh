#!/usr/bin/env bash
# Echo installed component versions and assert they match golden.json.
set -euo pipefail

GOLDEN_JSON="${GOLDEN_JSON:-/workspace/golden.json}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "${GOLDEN_JSON}" ]]; then
  echo "golden.json not found at ${GOLDEN_JSON}" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/activate-installer-python.sh"
# shellcheck source=golden-echo-test-versions.sh
source "${SCRIPT_DIR}/golden-echo-test-versions.sh"
# shellcheck source=golden-metal-images.sh
source "${SCRIPT_DIR}/golden-metal-images.sh"

golden_echo_test_banner "Verify installed vs golden.json"
golden_echo_golden_json_pins "${GOLDEN_JSON}"
echo "running:"
echo "  metal-version: $(read_golden_metal_version "${GOLDEN_JSON}")"
echo "  release image: $(resolve_metalium_release_image "${GOLDEN_JSON}")"
if golden_metal_upstream_enabled "${GOLDEN_JSON}"; then
  echo "  upstream image: $(resolve_metal_upstream_image "${GOLDEN_JSON}")"
else
  echo "  upstream image: (not configured — set metal-upstream-tag to enable)"
fi
echo ""

normalize_ver() {
  # Drop leading v and Debian/RPM revision suffix (e.g. 2.8.0-1 -> 2.8.0).
  sed -E 's/^v//; s/-[0-9].*$//; s/\+.*$//' <<<"$1"
}

versions_match() {
  local expected="$1"
  local actual="$2"
  [[ "$(normalize_ver "${expected}")" == "$(normalize_ver "${actual}")" ]]
}

read_installer_version() {
  local script="${1:-/tmp/tt-install.sh}"
  if [[ ! -f "${script}" ]]; then
    echo "unknown"
    return
  fi
  grep -E '^[[:space:]]*INSTALLER_VERSION=' "${script}" \
    | head -n1 \
    | sed -E 's/.*INSTALLER_VERSION="([^"]+)".*/\1/'
}

read_kmd_version() {
  if command -v dpkg-query >/dev/null 2>&1; then
    dpkg-query -W -f='${Version}' tenstorrent-dkms 2>/dev/null && return
  fi
  if command -v rpm >/dev/null 2>&1; then
    rpm -q --qf '%{VERSION}' tenstorrent-dkms 2>/dev/null && return
  fi
  echo "unknown"
}

read_cli_semver() {
  local cmd="$1"
  "${cmd}" -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}

run_cli_smoke_test() {
  local cmd="$1"
  local flag="$2"
  local expected_ver="${3:-}"

  echo ""
  echo "--- ${cmd} ${flag} ---"
  local output
  if ! output="$("${cmd}" "${flag}" 2>&1)"; then
    echo "FAIL: ${cmd} ${flag} exited non-zero" >&2
    return 1
  fi
  echo "${output}"

  case "${flag}" in
    -v)
      if [[ -z "${output}" ]]; then
        echo "FAIL: ${cmd} -v produced no output" >&2
        return 1
      fi
      if [[ -n "${expected_ver}" ]]; then
        local reported
        reported="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"${output}" | head -n1)"
        if ! versions_match "${expected_ver}" "${reported}"; then
          echo "FAIL: ${cmd} -v reported '${reported}', expected '${expected_ver}'" >&2
          return 1
        fi
      fi
      ;;
    -h)
      if [[ -z "${output}" ]]; then
        echo "FAIL: ${cmd} -h produced no output" >&2
        return 1
      fi
      if ! grep -Eiq 'usage|options|help|tt-smi|tt-flash' <<<"${output}"; then
        echo "FAIL: ${cmd} -h output does not look like help text" >&2
        return 1
      fi
      ;;
  esac

  echo "PASS: ${cmd} ${flag}"
  return 0
}

run_python_cli_smoke_tests() {
  local expected_smi="$1"
  local expected_flash="$2"
  local smoke_fail=0

  echo ""
  echo "=== Python CLI smoke tests ==="
  for cmd in tt-smi tt-flash; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      echo "FAIL: ${cmd} not found in PATH" >&2
      smoke_fail=1
      continue
    fi
  done

  if [[ "${smoke_fail}" -ne 0 ]]; then
    return 1
  fi

  run_cli_smoke_test tt-smi -v "${expected_smi}" || smoke_fail=1
  run_cli_smoke_test tt-flash -v "${expected_flash}" || smoke_fail=1
  run_cli_smoke_test tt-smi -h || smoke_fail=1
  run_cli_smoke_test tt-flash -h || smoke_fail=1

  return "${smoke_fail}"
}

read_smi_version() {
  read_cli_semver tt-smi
}

read_flash_version() {
  read_cli_semver tt-flash
}

EXPECTED_INSTALLER="$(jq -r '.installer' "${GOLDEN_JSON}")"
EXPECTED_KMD="$(jq -r '.kmd' "${GOLDEN_JSON}")"
EXPECTED_SMI="$(jq -r '.smi' "${GOLDEN_JSON}")"
EXPECTED_FLASH="$(jq -r '.flash' "${GOLDEN_JSON}")"

ACTUAL_INSTALLER="$(read_installer_version)"
ACTUAL_KMD="$(read_kmd_version)"
ACTUAL_SMI="$(read_smi_version)"
ACTUAL_FLASH="$(read_flash_version)"

fail=0
if ! run_python_cli_smoke_tests "${EXPECTED_SMI}" "${EXPECTED_FLASH}"; then
  fail=1
fi
check_row() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  local ok="PASS"
  if ! versions_match "${expected}" "${actual}"; then
    ok="FAIL"
    fail=1
  fi
  printf "| %-12s | %-14s | %-14s | %-4s |\n" "${name}" "${expected}" "${actual}" "${ok}"
}

echo ""
echo "=== Installed vs golden.json ==="
printf "| %-12s | %-14s | %-14s | %-4s |\n" "component" "golden" "installed" "ok"
printf "|%s|%s|%s|%s|\n" "--------------" "--------------" "--------------" "------"
check_row "installer" "${EXPECTED_INSTALLER}" "${ACTUAL_INSTALLER}"
check_row "kmd" "${EXPECTED_KMD}" "${ACTUAL_KMD}"
check_row "smi" "${EXPECTED_SMI}" "${ACTUAL_SMI}"
check_row "flash" "${EXPECTED_FLASH}" "${ACTUAL_FLASH}"
echo ""

if [[ "${fail}" -ne 0 ]]; then
  echo "One or more checks failed (golden.json version match and/or CLI smoke tests)." >&2
  exit 1
fi

echo "All checked versions match golden.json."
echo "Python CLI smoke tests (tt-smi/tt-flash -v and -h) passed."
