#!/usr/bin/env bash
# Activate installer Python venv and verify installed versions match golden.json.
set -euo pipefail
# Surface the location of any unexpected top-level abort instead of exiting
# silently. Not using errtrace (set -E) on purpose: the helpers below tolerate
# failures with `set +e`, and errtrace would fire this in their subshells.
trap 'rc=$?; echo "::error::verify-versions.sh aborted at line ${LINENO} (exit ${rc}): ${BASH_COMMAND}" >&2' ERR

GOLDEN_JSON="${GOLDEN_JSON:-/workspace/golden.json}"

if [[ ! -f "${GOLDEN_JSON}" ]]; then
  echo "golden.json not found at ${GOLDEN_JSON}" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

_resolve_installer_venv_dir() {
  if [[ -n "${VENV_DIR:-}" ]]; then
    printf '%s\n' "${VENV_DIR}"
    return 0
  fi
  if [[ -f /tmp/tenstorrent-installer-venv.path ]]; then
    cat /tmp/tenstorrent-installer-venv.path
    return 0
  fi
  local ttis_file=""
  for candidate in "${HOME}/.ttis" "/root/.ttis"; do
    if [[ -f "${candidate}" ]]; then
      ttis_file="${candidate}"
      break
    fi
  done
  if [[ -n "${ttis_file}" ]]; then
    local from_ttis
    from_ttis="$(jq -r '.python_env.location // empty' "${ttis_file}" 2>/dev/null || true)"
    if [[ -n "${from_ttis}" && "${from_ttis}" != "null" ]]; then
      printf '%s\n' "${from_ttis}"
      return 0
    fi
  fi
  if [[ "${EUID}" -eq 0 && -f /root/.tenstorrent-venv/bin/tt-smi ]]; then
    printf '%s\n' /root/.tenstorrent-venv
    return 0
  fi
  printf '%s\n' "${HOME}/.tenstorrent-venv"
}

VENV_DIR="$(_resolve_installer_venv_dir)"
if [[ ! -x "${VENV_DIR}/bin/tt-smi" ]]; then
  echo "Installer venv not found at ${VENV_DIR} (expected ${VENV_DIR}/bin/tt-smi)" >&2
  echo "Run golden-install.sh first or set VENV_DIR." >&2
  exit 1
fi
export VENV_DIR
export PATH="${VENV_DIR}/bin:${PATH}"

printf '\n========== Verify installed vs golden.json ==========\n'
echo "golden.json pins:"
jq -r '
  "  installer:     \(.installer)",
  "  kmd:           \(.kmd)",
  "  smi:           \(.smi)",
  "  flash:         \(.flash)",
  "  firmware:      \(.firmware)",
  "  metal-version: \(.["metal-version"] // .["metalium-image-tag"] // "n/a")",
  "  metal-upstream-tag: \(.["metal-upstream-tag"] // "(not set)")"
' "${GOLDEN_JSON}"
echo "venv: ${VENV_DIR}"
echo ""

normalize_ver() {
  sed -E 's/^v//; s/-[0-9].*$//; s/\+.*$//' <<<"$1"
}

versions_match() {
  [[ "$(normalize_ver "$1")" == "$(normalize_ver "$2")" ]]
}

read_installer_version() {
  local script="${1:-/tmp/tt-install.sh}"
  if [[ ! -f "${script}" ]]; then
    echo "unknown"
    return
  fi
  local v
  v="$(grep -E '^[[:space:]]*INSTALLER_VERSION=' "${script}" \
    | head -n1 \
    | sed -E 's/.*INSTALLER_VERSION="([^"]+)".*/\1/' || true)"
  printf '%s\n' "${v:-unknown}"
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
  # Tolerant: never aborts the caller. Returns the first semver from "<cmd> -v",
  # or empty if the command failed or printed none (the smoke test below reports
  # the full output and exit code in that case).
  local out
  set +e
  out="$("$1" -v 2>&1)"
  set -e
  printf '%s\n' "${out}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true
}

run_cli_smoke_test() {
  local cmd="$1"
  local flag="$2"
  local expected_ver="${3:-}"

  echo ""
  echo "--- ${cmd} ${flag} ---"
  local output rc
  set +e
  output="$("${cmd}" "${flag}" 2>&1)"
  rc=$?
  set -e
  # Always print the raw output (incl. tracebacks) so failures are diagnosable.
  printf '%s\n' "${output}"
  if [[ "${rc}" -ne 0 ]]; then
    echo "FAIL: ${cmd} ${flag} exited non-zero (exit ${rc})" >&2
    return 1
  fi

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

EXPECTED_INSTALLER="$(jq -r '.installer' "${GOLDEN_JSON}")"
EXPECTED_KMD="$(jq -r '.kmd' "${GOLDEN_JSON}")"
EXPECTED_SMI="$(jq -r '.smi' "${GOLDEN_JSON}")"
EXPECTED_FLASH="$(jq -r '.flash' "${GOLDEN_JSON}")"

ACTUAL_INSTALLER="$(read_installer_version)"
ACTUAL_KMD="$(read_kmd_version)"
ACTUAL_SMI="$(read_cli_semver tt-smi)"
ACTUAL_FLASH="$(read_cli_semver tt-flash)"

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
if [[ "${SKIP_INSTALLER_VERSION_CHECK:-0}" == "1" ]]; then
  # Installing from a release whose version differs from golden.json's `installer`
  # pin (e.g. a fork release used for testing). Report but don't fail on it.
  printf "| %-12s | %-14s | %-14s | %-4s |\n" "installer" "${EXPECTED_INSTALLER}" "${ACTUAL_INSTALLER}" "SKIP"
else
  check_row "installer" "${EXPECTED_INSTALLER}" "${ACTUAL_INSTALLER}"
fi
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
