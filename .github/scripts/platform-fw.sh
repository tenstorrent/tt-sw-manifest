#!/usr/bin/env bash
# Record the platform firmware on this host: BMC, BIOS, CPLDs, retimers and the
# Tenstorrent chip firmware. Read-only, and never fails the job: a value that
# cannot be read is recorded as "n/a" with the reason.
#
# Each value is written as one "FW|<key>|<value>" line to ${PLATFORM_FW_OUT}
# (platform-fw-summary.py compares these across hosts) and as a table to the
# step summary.
#
# Sources:
#   BMC            ipmitool mc info (firmware revision + aux bytes)
#   BIOS           dmidecode
#   CPLDs          BH Galaxy (Quanta S7T-MB) only: the same read-only IPMI I2C
#                  register reads as the vendor's cpld-dump.sh (tt-syseng-diag):
#                  ipmitool raw 0x06 0x52 <bus> <addr> 0x04 0x00
#   Chip firmware  tt-smi -s (fw bundle, CM, ETH, GDDR), unique values per host
#   Retimers       PCIe and ETH retimer firmware is not visible in-band. When
#                  BMC_USER and BMC_PASSWORD are set, the BMC's Redfish
#                  FirmwareInventory is listed instead, which carries them.
#
# Env:
#   PLATFORM_FW_OUT  output file (default ./platform-fw-$(hostname).txt)
#   VENV_DIR         venv holding tt-smi (default /root/.tenstorrent-venv)
#   BMC_USER, BMC_PASSWORD  optional, for Redfish
set -uo pipefail
# Runs under sudo; some hosts default to umask 027, which would leave the record
# unreadable to the runner user that uploads it.
umask 022

HOST="$(hostname)"
OUT="${PLATFORM_FW_OUT:-$(pwd)/platform-fw-${HOST}.txt}"
VENV_DIR="${VENV_DIR:-/root/.tenstorrent-venv}"
mkdir -p "$(dirname "${OUT}")"
: > "${OUT}"

put() { # put <key> <value>
  printf 'FW|%s|%s\n' "$1" "${2:-n/a}" | tee -a "${OUT}"
}

# --- Board identity ----------------------------------------------------------
fru=""
if command -v ipmitool >/dev/null; then
  fru="$(timeout 60 ipmitool fru print 0 2>/dev/null || true)"
fi
fru_field() { sed -n "s/^ *$1 *: *//p" <<< "${fru}" | head -1; }
BOARD_PRODUCT="$(fru_field 'Board Product')"
put host "${HOST}"
put board.product "${BOARD_PRODUCT:-n/a (ipmitool fru print 0 failed)}"
put board.serial "$(fru_field 'Board Serial')"
put system.product "$(dmidecode -s system-product-name 2>/dev/null || echo n/a)"

# --- BMC and BIOS ------------------------------------------------------------
if command -v ipmitool >/dev/null && mc="$(timeout 60 ipmitool mc info 2>/dev/null)"; then
  rev="$(sed -n 's/^Firmware Revision *: *//p' <<< "${mc}")"
  aux="$(sed -n '/^Aux Firmware Rev Info/,$p' <<< "${mc}" | grep -oE '0x[0-9a-fA-F]{2}' | paste -sd. -)"
  put bmc.firmware "${rev}${aux:+ (aux ${aux})}"
  put bmc.manufacturer "$(sed -n 's/^Manufacturer Name *: *//p' <<< "${mc}")"
  BMC_IP="$(timeout 30 ipmitool lan print 1 2>/dev/null | sed -n 's/^IP Address *: *//p' | head -1)"
else
  put bmc.firmware "n/a (ipmitool mc info failed)"
  BMC_IP=""
fi
put bios.version "$(dmidecode -s bios-version 2>/dev/null || echo n/a)"
put bios.date "$(dmidecode -s bios-release-date 2>/dev/null || echo n/a)"

# --- CPLDs (BH Galaxy only) --------------------------------------------------
# Bus/address pairs and the version decoding come from cpld-dump.sh V1.03.01.
# A reply is 4 bytes " pp mm MM id": version V<MM low digit>.<mm>.<pp>.
if [[ "${BOARD_PRODUCT}" == S7T-MB* ]]; then
  for entry in "mb 0x17 0x62" "pdb 0x09 0x62" "ubb1 0x0D 0x80" "ubb2 0x0F 0x80" \
               "ubb3 0x11 0x80" "ubb4 0x13 0x80"; do
    read -r name bus addr <<< "${entry}"
    v="$(timeout 30 ipmitool raw 0x06 0x52 "${bus}" "${addr}" 0x04 0x00 2>/dev/null)"
    if [[ "${v}" =~ ^\ [0-9a-f]{2}\ [0-9a-f]{2}\ [0-9a-f]{2}\ [0-9a-f]{2}$ && "${v}" != " 00 00 00 00" ]]; then
      put "cpld.${name}" "V${v:8:1}.${v:4:2}.${v:1:2}"
    else
      put "cpld.${name}" "n/a (no reply)"
    fi
  done
else
  put cpld "n/a (not a BH Galaxy S7T-MB board)"
fi

# --- Tenstorrent chip firmware (tt-smi -s) -----------------------------------
SMI="${VENV_DIR}/bin/tt-smi"
[[ -x "${SMI}" ]] || SMI="$(command -v tt-smi || true)"
snap="$(mktemp)"
if [[ -n "${SMI}" ]] && timeout 300 "${SMI}" -s > "${snap}" 2>/dev/null; then
  python3 - "${snap}" <<'PY' | tee -a "${OUT}"
import collections, json, sys
d = json.load(open(sys.argv[1]))
devs = d.get("device_info", [])
print(f"FW|chips|{len(devs)}")
for key in ("fw_bundle_version", "cm_fw", "eth_fw", "gddr_fw"):
    c = collections.Counter(str((x.get("firmwares") or {}).get(key, "n/a")) for x in devs)
    print(f"FW|chip.{key}|" + ", ".join(f"{v} (x{n})" if len(c) > 1 else v for v, n in c.most_common()))
PY
else
  put chips "n/a (tt-smi -s failed)"
fi
rm -f "${snap}"

# --- Retimers -----------------------------------------------------------------
redfish() { # redfish <path>: GET from the BMC; credentials go on stdin, not argv
  printf 'user = "%s:%s"\n' "${BMC_USER}" "${BMC_PASSWORD}" |
    timeout 60 curl -fsSk -K - "https://${BMC_IP}$1"
}
if [[ -n "${BMC_USER:-}" && -n "${BMC_PASSWORD:-}" && -n "${BMC_IP}" ]]; then
  if inv="$(redfish /redfish/v1/UpdateService/FirmwareInventory)"; then
    for id in $(python3 -c 'import json,sys; [print(m["@odata.id"]) for m in json.load(sys.stdin).get("Members", [])]' <<< "${inv}"); do
      redfish "${id}" | python3 -c '
import json, sys
m = json.load(sys.stdin)
print(f"FW|redfish.{m.get(\"Id\") or m.get(\"Name\")}|{m.get(\"Version\", \"n/a\")}")' | tee -a "${OUT}" ||
        put "redfish.${id##*/}" "n/a (request failed)"
    done
  else
    put redfish "n/a (Redfish FirmwareInventory request to the BMC at ${BMC_IP} failed)"
  fi
else
  put retimer.pcie "n/a (not readable in-band; set BMC_USER/BMC_PASSWORD for Redfish)"
  put retimer.eth "n/a (not readable in-band; set BMC_USER/BMC_PASSWORD for Redfish)"
fi

{
  echo "### Platform firmware on ${HOST}"
  echo
  echo "| Component | Version |"
  echo "|---|---|"
  awk -F'|' '{print "| " $2 " | " $3 " |"}' "${OUT}"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
exit 0
