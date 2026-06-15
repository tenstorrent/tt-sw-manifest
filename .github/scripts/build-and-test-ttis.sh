#!/usr/bin/env bash
# No-hardware compile → validate → install → verify → round-trip for one distro.
#
# Run as an unprivileged user (with passwordless sudo) inside the target distro,
# from the repo root. Produces golden/<distro>.ttis and proves it installs.
set -euo pipefail

GOLDEN_JSON="${GOLDEN_JSON:-./golden.json}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "── Compile golden.json → .ttis ──"
TTIS="$(GOLDEN_JSON="${GOLDEN_JSON}" bash "${SCRIPT_DIR}/compile-ttis.sh")"
echo "Compiled: ${TTIS}"
cat "${TTIS}"

INSTALLER_VER="$(jq -r '.installer' "${GOLDEN_JSON}")"
curl -fsSL \
  "https://github.com/tenstorrent/tt-installer/releases/download/v${INSTALLER_VER}/ttis.sh" \
  -o /tmp/ttis.sh

echo "── Validate ${TTIS} (ttis.sh @ v${INSTALLER_VER}) ──"
bash /tmp/ttis.sh validate "${TTIS}"

echo "── Install from ${TTIS} ──"
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
