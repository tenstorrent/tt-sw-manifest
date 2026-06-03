#!/usr/bin/env bash
# PCI reset stress: run `tt-smi -r` (reset all devices) NUM_RESETS times using the installer venv.
# Invoked via sudo on self-hosted HW runners; see golden-hw.yml for the harmless
# "sudo: unable to resolve host ubuntu" log line when hostname is missing from /etc/hosts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NUM_RESETS="${NUM_RESETS:-10}"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/activate-installer-python.sh"

echo "=== tt-smi PCI reset stress (${NUM_RESETS} iterations) ==="

for ((attempt = 1; attempt <= NUM_RESETS; attempt++)); do
  echo "--- tt-smi -r (${attempt}/${NUM_RESETS}) ---"
  tt-smi -r
  echo "PASS: reset ${attempt}/${NUM_RESETS}"
done

echo "PASS: ${NUM_RESETS} consecutive PCI resets succeeded"
