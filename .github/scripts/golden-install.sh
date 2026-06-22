#!/usr/bin/env bash
# Install kmd / tt-smi / tt-flash (and optionally metalium) via tt-installer at golden.json pins.
#
# Usage:
#   golden-install.sh [--hw] [--force-flash]
#   golden-install.sh --ttis <file>
#   golden-install.sh --export <file>
#
#   --hw           Hardware runner: hugepages, metalium container, container runtime,
#                  upstream-tests-bh pull. Requires root.
#   --force-flash  Flash firmware during install (default: off).
#   --ttis <file>  No-hardware install driven by a compiled .ttis file via
#                  tt-installer --import-schema (version pins come from the file,
#                  not from individual flags). Mutually exclusive with --hw.
#   --export <file> No-hardware install of the full host software stack (kmd +
#                  tenstorrent-tools/hugepages + sfpi + tt-smi/tt-flash) at
#                  golden.json pins, then tt-installer --export-schema captures the
#                  actually-installed versions into <file>. Firmware is recorded
#                  from golden.json (assumed-flashed; never actually flashed here)
#                  and machine-specific python_env fields are normalized for
#                  portability. Mutually exclusive with --hw and --ttis.
set -euo pipefail

GOLDEN_JSON="${GOLDEN_JSON:-/workspace/golden.json}"
INSTALLER_URL="${INSTALLER_URL:-}"
# Release source for install.sh / ttis.sh. Defaults to the upstream repo and the
# golden.json `installer` pin; override INSTALLER_REPO / INSTALLER_TAG to test
# against another release (e.g. a fork) without touching golden.json.
INSTALLER_REPO="${INSTALLER_REPO:-tenstorrent/tt-installer}"
INSTALLER_TAG="${INSTALLER_TAG:-}"
HW="${GOLDEN_HW:-0}"
FORCE_FLASH="${FORCE_FLASH:-0}"
TTIS_FILE="${TTIS_FILE:-}"
EXPORT_FILE="${EXPORT_FILE:-}"
PY_VERSION="${PY_VERSION:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hw) HW=1; shift ;;
    --force-flash) FORCE_FLASH=1; shift ;;
    --ttis) TTIS_FILE="${2:?--ttis requires a file path}"; shift 2 ;;
    --export) EXPORT_FILE="${2:?--export requires a file path}"; shift 2 ;;
    -h | --help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

if [[ "${HW}" -eq 1 && "${EUID}" -ne 0 ]]; then
  echo "Run as root (sudo) for --hw installs." >&2
  exit 1
fi

if [[ -n "${EXPORT_FILE}" && -n "${TTIS_FILE}" ]]; then
  echo "--export and --ttis are mutually exclusive." >&2
  exit 2
fi
if [[ -n "${EXPORT_FILE}" && "${HW}" -eq 1 ]]; then
  echo "--export is a no-hardware path; do not combine with --hw." >&2
  exit 2
fi

if [[ ! -f "${GOLDEN_JSON}" ]]; then
  echo "golden.json not found at ${GOLDEN_JSON}" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

readonly GOLDEN_METALIUM_RELEASE_REPO="ghcr.io/tenstorrent/tt-metal/tt-metalium-ubuntu-22.04-release-amd64"
readonly GOLDEN_METAL_UPSTREAM_REPO="ghcr.io/tenstorrent/tt-metal/upstream-tests-bh"

normalize_metal_image_tag() {
  local tag="${1:?}"
  case "${tag}" in
    latest-rc | latest) printf '%s\n' "${tag}" ;;
    v*) printf '%s\n' "${tag}" ;;
    *) printf 'v%s\n' "${tag}" ;;
  esac
}

read_golden_metal_version() {
  jq -r '.["metal-version"] // .["metalium-image-tag"] // empty' "${GOLDEN_JSON}"
}

read_golden_metal_upstream_tag() {
  jq -r '.["metal-upstream-tag"] // empty' "${GOLDEN_JSON}"
}

metalium_release_image_ref() {
  printf '%s:%s\n' "${GOLDEN_METALIUM_RELEASE_REPO}" "$(normalize_metal_image_tag "$1")"
}

metal_upstream_image_ref() {
  printf '%s:%s\n' "${GOLDEN_METAL_UPSTREAM_REPO}" "$(normalize_metal_image_tag "$1")"
}

INSTALLER_VER="$(jq -r '.installer' "${GOLDEN_JSON}")"
KMD_VER="$(jq -r '.kmd' "${GOLDEN_JSON}")"
SMI_VER="$(jq -r '.smi' "${GOLDEN_JSON}")"
FLASH_VER="$(jq -r '.flash' "${GOLDEN_JSON}")"
SFPI_VER="$(jq -r '.sfpi // empty' "${GOLDEN_JSON}")"
TOOLS_VER="$(jq -r '.tools // empty' "${GOLDEN_JSON}")"
FW_VER="$(jq -r '.firmware' "${GOLDEN_JSON}")"

INSTALLER_TAG="${INSTALLER_TAG:-v${INSTALLER_VER}}"
if [[ -z "${INSTALLER_URL}" ]]; then
  INSTALLER_URL="https://github.com/${INSTALLER_REPO}/releases/download/${INSTALLER_TAG}/install.sh"
fi

record_installer_venv() {
  local venv="${HOME}/.tenstorrent-venv"
  if [[ -x "${venv}/bin/python" ]]; then
    echo "${venv}" > /tmp/tenstorrent-installer-venv.path
    echo "Installer Python venv recorded at ${venv}"
  else
    echo "WARNING: expected installer venv not found at ${venv}/bin/python" >&2
  fi
}

# ── .ttis import mode (no hardware) ──────────────────────────────────────────
# Install the stack from a compiled .ttis file. tt-installer's install.sh sources
# ttis.sh from its own directory, so we fetch both into /tmp. Version pins,
# hugepages/sfpi, firmware (off) and container runtime all come from the file;
# only the non-schema components are disabled here.
if [[ -n "${TTIS_FILE}" ]]; then
  if [[ "${HW}" -eq 1 ]]; then
    echo "--ttis is a no-hardware path; do not combine with --hw" >&2
    exit 2
  fi
  if [[ ! -f "${TTIS_FILE}" ]]; then
    echo "ttis file not found at ${TTIS_FILE}" >&2
    exit 1
  fi
  TTIS_URL="${TTIS_URL:-https://github.com/${INSTALLER_REPO}/releases/download/${INSTALLER_TAG}/ttis.sh}"

  echo "=== Golden install (import .ttis, no hardware) ==="
  echo "golden.json: ${GOLDEN_JSON}"
  echo "ttis file:   ${TTIS_FILE}"
  echo "installer:   ${INSTALLER_REPO}@${INSTALLER_TAG} (${INSTALLER_URL})"

  curl -fsSL "${INSTALLER_URL}" -o /tmp/tt-install.sh
  curl -fsSL "${TTIS_URL}" -o /tmp/ttis.sh
  chmod +x /tmp/tt-install.sh

  # Optional extra installer flags (e.g. --use-uv), supplied by the caller.
  TTIS_EXTRA_ARGS=()
  if [[ -n "${INSTALL_EXTRA_ARGS:-}" ]]; then
    read -ra TTIS_EXTRA_ARGS <<< "${INSTALL_EXTRA_ARGS}"
  fi

  timeout 900 bash /tmp/tt-install.sh \
    --mode-non-interactive \
    --import-schema "${TTIS_FILE}" \
    ${TTIS_EXTRA_ARGS[@]+"${TTIS_EXTRA_ARGS[@]}"} \
    --no-install-metalium-container \
    --no-install-metalium-models-container \
    --no-install-forge-container \
    --no-install-inference-server \
    --no-install-studio \
    --reboot-option never

  record_installer_venv
  echo "=== Install finished (import) ==="
  exit 0
fi

if [[ "${FORCE_FLASH}" -eq 1 ]]; then
  FW_UPDATE_ARGS=(--update-firmware force)
  FW_NOTE="flash enabled (--force-flash)"
else
  FW_UPDATE_ARGS=(--update-firmware off)
  FW_NOTE="flash disabled (default)"
fi

if [[ "${HW}" -eq 1 ]]; then
  METAL_VERSION="$(normalize_metal_image_tag "$(read_golden_metal_version)")"
  METALIUM_RELEASE_IMAGE="$(metalium_release_image_ref "${METAL_VERSION}")"
  METAL_UPSTREAM_TAG="$(read_golden_metal_upstream_tag)"

  CONTAINER_RUNTIME="docker"
  if command -v docker >/dev/null 2>&1; then
    CONTAINER_RUNTIME="docker"
  elif command -v podman >/dev/null 2>&1; then
    CONTAINER_RUNTIME="podman"
  else
    echo "WARNING: neither docker nor podman found; metalium container install may fail" >&2
  fi

  echo "=== Golden install (hardware) ==="
  echo "golden.json: ${GOLDEN_JSON}"
  echo "installer:   v${INSTALLER_VER} (${INSTALLER_URL})"
  echo "kmd:         ${KMD_VER}"
  echo "smi:         ${SMI_VER}"
  echo "flash:       ${FLASH_VER}"
  echo "firmware:    ${FW_VER} (${FW_NOTE})"
  echo "metal-version: ${METAL_VERSION}"
  echo "  release:   ${METALIUM_RELEASE_IMAGE} (installer)"
  if [[ -n "${METAL_UPSTREAM_TAG}" ]]; then
    echo "  upstream:  $(metal_upstream_image_ref "${METAL_UPSTREAM_TAG}") (golden CI only)"
  else
    echo "  upstream:  (skipped — metal-upstream-tag not set)"
  fi

  INSTALL_TIMEOUT=1800
  HUGE_PAGES_ARGS=(--install-hugepages)
  METALIUM_ARGS=(--install-metalium-container)
  CONTAINER_RUNTIME_ARGS=(--install-container-runtime "${CONTAINER_RUNTIME}")
  METALIUM_TAG_ARGS=(--metalium-image-tag "${METAL_VERSION}")
  SFPI_ARGS=(--no-install-sfpi)
  PYTHON_ARGS=(--python-choice new-venv)
  EXPORT_ARGS=()
else
  echo "=== Golden install (no hardware${EXPORT_FILE:+, export schema}) ==="
  echo "golden.json: ${GOLDEN_JSON}"
  echo "installer:   v${INSTALLER_VER} (${INSTALLER_URL})"
  echo "kmd:         ${KMD_VER}"
  echo "smi:         ${SMI_VER}"
  echo "flash:       ${FLASH_VER}"
  echo "firmware:    ${FW_VER} (${FW_NOTE})"

  INSTALL_TIMEOUT=900
  METALIUM_ARGS=(--no-install-metalium-container)
  CONTAINER_RUNTIME_ARGS=(--install-container-runtime no)
  METALIUM_TAG_ARGS=()

  if [[ -n "${EXPORT_FILE}" ]]; then
    # Export run: install the whole host software stack so --export-schema can
    # resolve real versions for tenstorrent-tools (gated by --install-hugepages)
    # and sfpi. The installer sources ttis.sh from its own directory, so fetch it
    # next to install.sh (the import path does the same).
    echo "sfpi:        ${SFPI_VER:-(latest)}"
    echo "tools:       ${TOOLS_VER:-(latest)}"
    echo "export:      ${EXPORT_FILE}"
    HUGE_PAGES_ARGS=(--install-hugepages)
    [[ -n "${TOOLS_VER}" ]] && HUGE_PAGES_ARGS+=(--systools-version "${TOOLS_VER}")
    SFPI_ARGS=(--install-sfpi)
    [[ -n "${SFPI_VER}" ]] && SFPI_ARGS+=(--sfpi-version "${SFPI_VER}")
    EXPORT_ARGS=(--export-schema "${EXPORT_FILE}")
    mkdir -p "$(dirname "${EXPORT_FILE}")"
    # ttis_export refuses to overwrite an existing file (no --force from install.sh).
    rm -f "${EXPORT_FILE}"
    TTIS_URL="${TTIS_URL:-https://github.com/${INSTALLER_REPO}/releases/download/${INSTALLER_TAG}/ttis.sh}"
    curl -fsSL "${TTIS_URL}" -o /tmp/ttis.sh
  else
    HUGE_PAGES_ARGS=(--no-install-hugepages)
    SFPI_ARGS=(--no-install-sfpi)
    EXPORT_ARGS=()
  fi

  # Fedora ships a Python that tt-umd (a tt-smi dependency) has no wheels for; pin
  # and provision via uv so the venv — and the exported python_version — is
  # reproducible. PY_VERSION may be overridden via the environment.
  if [[ -z "${PY_VERSION}" && "$( . /etc/os-release 2>/dev/null; echo "${ID:-}" )" == "fedora" ]]; then
    PY_VERSION="3.12"
  fi
  PYTHON_ARGS=(--python-choice new-venv)
  if [[ -n "${PY_VERSION}" ]]; then
    PYTHON_ARGS+=(--use-uv --python-version "${PY_VERSION}")
  fi
fi

curl -fsSL "${INSTALLER_URL}" -o /tmp/tt-install.sh
chmod +x /tmp/tt-install.sh

timeout "${INSTALL_TIMEOUT}" bash /tmp/tt-install.sh \
  --mode-non-interactive \
  --install-kmd \
  "${HUGE_PAGES_ARGS[@]}" \
  "${FW_UPDATE_ARGS[@]}" \
  "${METALIUM_ARGS[@]}" \
  --no-install-metalium-models-container \
  --no-install-forge-container \
  "${SFPI_ARGS[@]}" \
  --no-install-inference-server \
  --no-install-studio \
  "${CONTAINER_RUNTIME_ARGS[@]}" \
  "${PYTHON_ARGS[@]}" \
  --reboot-option never \
  --kmd-version "${KMD_VER}" \
  --smi-version "${SMI_VER}" \
  --flash-version "${FLASH_VER}" \
  --fw-version "${FW_VER}" \
  "${METALIUM_TAG_ARGS[@]}" \
  ${EXPORT_ARGS[@]+"${EXPORT_ARGS[@]}"}

record_installer_venv

# Normalize the exported state file: record firmware from golden.json (assumed
# flashed — we never flash without a device) and blank machine-specific python_env
# fields so the golden is portable. python_version keeps the intended pin (Fedora)
# rather than whatever interpreter happened to back the venv on this runner.
if [[ -n "${EXPORT_FILE}" ]]; then
  if [[ ! -f "${EXPORT_FILE}" ]]; then
    echo "Expected exported schema at ${EXPORT_FILE} but it was not created" >&2
    exit 1
  fi
  echo "Normalizing ${EXPORT_FILE}: firmware=${FW_VER} (assumed-flashed), python_version=${PY_VERSION:-(none)}, location cleared"
  _tmp_ttis="$(mktemp)"
  jq --arg fw "${FW_VER}" --arg pyv "${PY_VERSION}" \
    '.firmware.version = $fw
     | .python_env.location = ""
     | .python_env.python_version = $pyv' \
    "${EXPORT_FILE}" > "${_tmp_ttis}"
  mv "${_tmp_ttis}" "${EXPORT_FILE}"
fi

if [[ "${HW}" -eq 1 ]]; then
  TT_METALIUM_WRAPPER="${HOME}/.local/bin/tt-metalium"
  if [[ -x "${TT_METALIUM_WRAPPER}" ]]; then
    grep -E '^METALIUM_IMAGE=' "${TT_METALIUM_WRAPPER}" | head -n1 | cut -d= -f2- | tr -d '"' \
      > /tmp/tenstorrent-metalium-image.path || true
    echo "Installer tt-metalium image: $(cat /tmp/tenstorrent-metalium-image.path 2>/dev/null || echo unknown)"
  fi

  if [[ -n "${METAL_UPSTREAM_TAG}" ]]; then
    METAL_UPSTREAM_IMAGE="$(metal_upstream_image_ref "${METAL_UPSTREAM_TAG}")"
    echo "Pulling upstream-tests-bh (golden metal upstream step; not part of tt-installer)..."
    if ${CONTAINER_RUNTIME} pull "${METAL_UPSTREAM_IMAGE}"; then
      echo "${METAL_UPSTREAM_IMAGE}" > /tmp/tenstorrent-metal-upstream-image.path
    else
      echo "WARNING: failed to pull ${METAL_UPSTREAM_IMAGE}; upstream step will retry pull" >&2
      echo "${METAL_UPSTREAM_IMAGE}" > /tmp/tenstorrent-metal-upstream-image.path
    fi
  else
    echo "Skipping upstream-tests-bh pull (metal-upstream-tag not set in golden.json)."
    rm -f /tmp/tenstorrent-metal-upstream-image.path
  fi
fi

echo "=== Install finished ==="
