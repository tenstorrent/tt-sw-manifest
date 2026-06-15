#!/usr/bin/env bash
# No-hardware compile → validate → install → verify → round-trip for one distro.
#
# Run as an unprivileged user (with passwordless sudo) inside the target distro,
# from the repo root. Produces golden/<distro>.ttis and proves it installs via
# tt-installer --import-schema.
#
# install.sh and ttis.sh both come from a tt-installer release, selected by
# INSTALLER_REPO / INSTALLER_TAG (default: tenstorrent + golden.json `installer`).
set -euo pipefail

GOLDEN_JSON="${GOLDEN_JSON:-./golden.json}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "── Compile golden.json → .ttis ──"
TTIS="$(GOLDEN_JSON="${GOLDEN_JSON}" bash "${SCRIPT_DIR}/compile-ttis.sh")"
echo "Compiled: ${TTIS}"
cat "${TTIS}"

INSTALLER_VER="$(jq -r '.installer' "${GOLDEN_JSON}")"
INSTALLER_REPO="${INSTALLER_REPO:-tenstorrent/tt-installer}"
INSTALLER_TAG="${INSTALLER_TAG:-v${INSTALLER_VER}}"
TTIS_URL="${TTIS_URL:-https://github.com/${INSTALLER_REPO}/releases/download/${INSTALLER_TAG}/ttis.sh}"
echo "── Fetch ttis.sh (${TTIS_URL}) ──"
curl -fsSL "${TTIS_URL}" -o /tmp/ttis.sh

echo "── Validate ${TTIS} ──"
bash /tmp/ttis.sh validate "${TTIS}"

echo "── Install golden stack from ${INSTALLER_REPO}@${INSTALLER_TAG} (--import-schema) ──"
GOLDEN_JSON="${GOLDEN_JSON}" bash "${SCRIPT_DIR}/golden-install.sh" --ttis "${TTIS}"

echo "── Verify installed versions match golden.json ──"
GOLDEN_JSON="${GOLDEN_JSON}" bash "${SCRIPT_DIR}/verify-versions.sh"

echo "── Import round-trip ──"
case "$(jq -r '.meta.distro_family' "${TTIS}")" in
  apt) PM=apt-get ;;
  dnf) PM=dnf ;;
  *) echo "unexpected distro_family in ${TTIS}" >&2; exit 1 ;;
esac
DID="$(jq -r '.meta.distro_id' "${TTIS}")"
PKG_MANAGER="${PM}" DISTRO_ID="${DID}" TTIS_FILE="${TTIS}" bash -c '
  source /tmp/ttis.sh
  ttis_import "${TTIS_FILE}"
  [[ "${_arg_install_kmd:-}" =~ ^(on|off)$ ]] || { echo "round-trip: _arg_install_kmd not set"; exit 1; }
  echo "round-trip ok: kmd=${_arg_kmd_version:-} smi=${_arg_smi_version:-} flash=${_arg_flash_version:-}"
'

echo "All .ttis checks passed for ${TTIS}"
