#!/usr/bin/env bash
# Compile golden.json into a tt-installer .ttis state file (schema v1).
#
# Emits a no-hardware golden: the software stack (kmd / tt-smi / tt-flash + venv)
# with hugepages, sfpi, firmware flashing and container runtime all disabled.
# Firmware MUST stay empty here — a non-empty firmware.version makes tt-installer
# flash on import, which has no meaning (and fails) without a device.
#
# Versions are carried verbatim from golden.json (clean semver). The install test
# is what proves they are installable on the target distro.
#
# Usage:
#   compile-ttis.sh [--out <file>] [--distro-id <id>] [--distro-version <ver>] [--family apt|dnf]
#
# Distro fields default to /etc/os-release. The resolved output path is printed
# to stdout (all logging goes to stderr) so callers can capture it.
set -euo pipefail

GOLDEN_JSON="${GOLDEN_JSON:-./golden.json}"
OUT=""
DISTRO_ID=""
DISTRO_VERSION=""
DISTRO_FAMILY=""

log() { echo "[compile-ttis] $*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --distro-id) DISTRO_ID="$2"; shift 2 ;;
    --distro-version) DISTRO_VERSION="$2"; shift 2 ;;
    --family) DISTRO_FAMILY="$2"; shift 2 ;;
    -h | --help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -f "${GOLDEN_JSON}" ]]; then
  echo "golden.json not found at ${GOLDEN_JSON}" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

if [[ -z "${DISTRO_ID}" || -z "${DISTRO_VERSION}" ]]; then
  if [[ ! -r /etc/os-release ]]; then
    echo "cannot detect distro: /etc/os-release missing; pass --distro-id/--distro-version" >&2
    exit 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO_ID="${DISTRO_ID:-${ID:-}}"
  DISTRO_VERSION="${DISTRO_VERSION:-${VERSION_ID:-}}"
fi

if [[ -z "${DISTRO_FAMILY}" ]]; then
  case "${DISTRO_ID}" in
    ubuntu | debian) DISTRO_FAMILY="apt" ;;
    fedora | rhel | centos | rocky | almalinux) DISTRO_FAMILY="dnf" ;;
    *) echo "unknown distro family for '${DISTRO_ID}'; pass --family apt|dnf" >&2; exit 1 ;;
  esac
fi

if [[ -z "${DISTRO_ID}" || -z "${DISTRO_VERSION}" ]]; then
  echo "could not resolve distro id/version" >&2
  exit 1
fi

OUT="${OUT:-golden/${DISTRO_ID}-${DISTRO_VERSION}.ttis}"
mkdir -p "$(dirname "${OUT}")"

KMD="$(jq -r '.kmd' "${GOLDEN_JSON}")"
SMI="$(jq -r '.smi' "${GOLDEN_JSON}")"
FLASH="$(jq -r '.flash' "${GOLDEN_JSON}")"
INSTALLER="$(jq -r '.installer' "${GOLDEN_JSON}")"

log "golden.json: ${GOLDEN_JSON}"
log "target: ${DISTRO_ID} ${DISTRO_VERSION} (${DISTRO_FAMILY})"
log "kmd=${KMD} smi=${SMI} flash=${FLASH} installer=${INSTALLER}"

jq -n \
  --arg iv "${INSTALLER}" \
  --arg ca "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg di "${DISTRO_ID}" \
  --arg dv "${DISTRO_VERSION}" \
  --arg df "${DISTRO_FAMILY}" \
  --arg kmd "${KMD}" \
  --arg smi "${SMI}" \
  --arg flash "${FLASH}" \
  '{
    meta: {
      schema_version: 1,
      installer_version: $iv,
      created_at: $ca,
      distro_id: $di,
      distro_version: $dv,
      distro_family: $df,
      hostname: "github-actions"
    },
    tt_system:  { "tenstorrent-dkms": $kmd, "tenstorrent-tools": "", "sfpi": "" },
    tt_python:  { "tt-smi": $smi, "tt-flash": $flash },
    firmware:   { version: "" },
    container_runtime: { runtime: "none" },
    python_env: { method: "venv", location: "" }
  }' > "${OUT}"

log "wrote ${OUT}"
printf '%s\n' "${OUT}"
