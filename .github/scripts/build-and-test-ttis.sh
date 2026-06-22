#!/usr/bin/env bash
# No-hardware install → export schema → validate → verify → import round-trip
# for one distro.
#
# Run as an unprivileged user (with passwordless sudo) inside the target distro,
# from the repo root. Installs the golden stack via tt-installer at golden.json
# pins, then captures the actually-installed versions with --export-schema into
# golden/<distro>.ttis — that exported file is what gets released.
#
# install.sh and ttis.sh both come from a tt-installer release, selected by
# INSTALLER_REPO / INSTALLER_TAG (default: tenstorrent + golden.json `installer`).
set -euo pipefail

GOLDEN_JSON="${GOLDEN_JSON:-./golden.json}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Output path mirrors the distro (id-version), matching the release layout.
# shellcheck disable=SC1091
. /etc/os-release
TTIS="golden/${ID:-unknown}-${VERSION_ID:-unknown}.ttis"

INSTALLER_VER="$(jq -r '.installer' "${GOLDEN_JSON}")"
INSTALLER_REPO="${INSTALLER_REPO:-tenstorrent/tt-installer}"
INSTALLER_TAG="${INSTALLER_TAG:-v${INSTALLER_VER}}"
TTIS_URL="${TTIS_URL:-https://github.com/${INSTALLER_REPO}/releases/download/${INSTALLER_TAG}/ttis.sh}"

echo "── Install golden stack from ${INSTALLER_REPO}@${INSTALLER_TAG} + export schema → ${TTIS} ──"
GOLDEN_JSON="${GOLDEN_JSON}" bash "${SCRIPT_DIR}/golden-install.sh" --export "${TTIS}"

echo "── Exported ${TTIS} ──"
cat "${TTIS}"

echo "── Fetch ttis.sh (${TTIS_URL}) ──"
curl -fsSL "${TTIS_URL}" -o /tmp/ttis.sh

echo "── Validate ${TTIS} ──"
bash /tmp/ttis.sh validate "${TTIS}"

echo "── Verify installed versions match golden.json ──"
GOLDEN_JSON="${GOLDEN_JSON}" bash "${SCRIPT_DIR}/verify-versions.sh"

echo "── Import round-trip (proves the exported file is consumable) ──"
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
  echo "round-trip ok: kmd=${_arg_kmd_version:-} tools=${_arg_systools_version:-} sfpi=${_arg_sfpi_version:-} smi=${_arg_smi_version:-} flash=${_arg_flash_version:-} fw=${_arg_fw_version:-}"
'

echo "All .ttis checks passed for ${TTIS}"
