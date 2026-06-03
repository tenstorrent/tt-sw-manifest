#!/usr/bin/env bash
# Local Blackhole (p150b): tt-installer without firmware flash, then full upstream suite.
# No smi reset, verify, or metal unit test — upstream only after install.
#
# Full reinstall (remove images, re-install with hugepages, run upstream):
#   sudo ./local_bh_upstream_tests.sh --remove-images
#
# Upstream only (install already done, hugepages OK):
#   sudo ./local_bh_upstream_tests.sh --skip-install
#
# All output → test.log (override with GOLDEN_RUN_LOG=/path/to.log)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${REPO_ROOT}/.github/scripts"
GOLDEN_JSON="${REPO_ROOT}/golden.json"

readonly GOLDEN_RUNNER_LABEL="tt-ubuntu-2204-p150b-stable"

REMOVE_IMAGES=0
SKIP_INSTALL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --remove-images) REMOVE_IMAGES=1; shift ;;
    --skip-install) SKIP_INSTALL=1; shift ;;
    -h | --help)
      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
      echo ""
      echo "Options:"
      echo "  --remove-images   docker rmi upstream (+ release) images from golden.json before install"
      echo "  --skip-install    run upstream tests only"
      exit 0
      ;;
    *)
      echo "Unknown option: $1 (try --help)" >&2
      exit 2
      ;;
  esac
done

if [[ "${EUID}" -ne 0 ]]; then
  echo "Re-execing as root (sudo)..."
  exec sudo -E bash "${REPO_ROOT}/local_bh_upstream_tests.sh" "$@"
fi

# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/golden-metal-images.sh"
# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/golden-check-hugepages.sh"

if [[ ! -f "${GOLDEN_JSON}" ]]; then
  echo "golden.json not found at ${GOLDEN_JSON}" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required (e.g. apt install jq)" >&2
  exit 1
fi

if [[ ! -e /dev/tenstorrent ]]; then
  echo "WARNING: /dev/tenstorrent not found — is this a Blackhole host with KMD loaded?" >&2
fi

METAL_UPSTREAM_TAG="$(read_golden_metal_upstream_tag "${GOLDEN_JSON}")"
METAL_VERSION="$(normalize_metal_image_tag "$(read_golden_metal_version "${GOLDEN_JSON}")")"
UPSTREAM_IMAGE="$(metal_upstream_image_ref "${METAL_UPSTREAM_TAG}")"
RELEASE_IMAGE="$(metalium_release_image_ref "${METAL_VERSION}")"

local_remove_golden_images() {
  echo "=== Removing golden container images (optional fresh pull) ==="
  for image in "${UPSTREAM_IMAGE}" "${RELEASE_IMAGE}"; do
    if docker image inspect "${image}" >/dev/null 2>&1; then
      echo "  docker rmi ${image}"
      docker rmi "${image}" || true
    else
      echo "  (not present) ${image}"
    fi
  done
  rm -f /tmp/tenstorrent-metal-upstream-image.path /tmp/tenstorrent-metalium-image.path
  echo ""
}

local_verify_hugepages() {
  echo "=== Hugepages check (required for upstream UMD tests) ==="
  ls -ld /dev/hugepages /dev/hugepages-1G 2>/dev/null || echo "  (hugepage mounts not listed)"
  if grep -qi huge /proc/meminfo 2>/dev/null; then
    grep -i huge /proc/meminfo | sed 's/^/  /'
  fi
  if golden_check_hugepages; then
    echo "  PASS: hugepage mounts present"
    return 0
  fi
  echo ""
  echo "Hugepages are missing. Install uses --install-hugepages (tenstorrent-tools)." >&2
  echo "After first setup you may need: sudo reboot" >&2
  echo "Then re-run: sudo ./local_bh_upstream_tests.sh --skip-install" >&2
  return 1
}

RUN_LOG="${GOLDEN_RUN_LOG:-${REPO_ROOT}/test.log}"
mkdir -p "$(dirname "${RUN_LOG}")"
export GOLDEN_UPSTREAM_LOG_FILE="${RUN_LOG}"
echo "All stdout/stderr for this run → ${RUN_LOG}"
exec > >(tee "${RUN_LOG}") 2>&1

printf '\n======================================================================\n'
echo "  Local BH upstream run"
printf '======================================================================\n\n'
echo "Repo:            ${REPO_ROOT}"
echo "golden.json:     ${GOLDEN_JSON}"
echo "Firmware flash:  off"
echo "Hugepages:       enabled via tt-installer (--install-hugepages)"
echo "Install profile: upstream-local (skip Docker reinstall if already present)"
echo "Upstream:        full blackhole_no_models"
echo "Remove images:   ${REMOVE_IMAGES}"
echo "Skip install:    ${SKIP_INSTALL}"
echo ""

START_TS="$(date +%s)"

if [[ "${REMOVE_IMAGES}" -eq 1 ]]; then
  local_remove_golden_images
fi

if [[ "${SKIP_INSTALL}" -eq 0 ]]; then
  echo "=== Step 1/2: Install (tt-installer, no firmware flash, with hugepages) ==="
  export GOLDEN_JSON
  export GOLDEN_UPDATE_FIRMWARE=off
  export GOLDEN_INSTALL_PROFILE=upstream-local
  bash "${SCRIPTS_DIR}/golden-install-hw.sh"
  echo ""
  local_verify_hugepages
  echo ""
else
  echo "=== Step 1/2: Install (skipped) ==="
  local_verify_hugepages
  echo ""
fi

echo "=== Step 2/2: Metal upstream tests (full suite) ==="
export GOLDEN_JSON
export GOLDEN_RUNNER_LABEL
export GITHUB_RUNNER_NAME="${GOLDEN_RUNNER_LABEL}"
bash "${SCRIPTS_DIR}/golden-metal-upstream.sh"

ELAPSED=$(( $(date +%s) - START_TS ))
printf '\n======================================================================\n'
echo "  PASS — local BH upstream run finished (${ELAPSED}s)"
printf '======================================================================\n'
echo "Full log file: ${RUN_LOG}"
