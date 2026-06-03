#!/usr/bin/env bash
# Fail fast before metal container tests if host hugepages are not set up.
set -euo pipefail

golden_check_hugepages() {
  if [[ -d /dev/hugepages-1G ]] || [[ -d /dev/hugepages ]]; then
    return 0
  fi
  echo "FAIL: host hugepages are not configured (/dev/hugepages-1G and /dev/hugepages missing)." >&2
  echo "  Run tt-installer with hugepages enabled (golden-install-hw.sh uses --install-hugepages)." >&2
  echo "  A reboot may be required after the first hugepages setup." >&2
  return 1
}
