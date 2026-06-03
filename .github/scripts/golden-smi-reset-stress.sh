#!/usr/bin/env bash
# PCI reset stress: run `tt-smi -r` (reset all devices) NUM_RESETS times using the installer venv.
# Invoked via sudo on self-hosted HW runners; see golden-hw.yml for the harmless
# "sudo: unable to resolve host ubuntu" log line when hostname is missing from /etc/hosts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GOLDEN_JSON="${GOLDEN_JSON:-${REPO_ROOT}/golden.json}"
NUM_RESETS="${NUM_RESETS:-10}"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/activate-installer-python.sh"
# shellcheck source=golden-echo-test-versions.sh
source "${SCRIPT_DIR}/golden-echo-test-versions.sh"

golden_echo_test_banner "PCI reset stress (tt-smi -r)"
golden_echo_golden_json_pins "${GOLDEN_JSON}"
echo "running:"
echo "  command:     tt-smi -r (×${NUM_RESETS})"
echo "  tt-smi:      $(tt-smi -v 2>&1 | head -n1)"
echo "  python:      ${TENSTORRENT_PYTHON:-unknown}"
echo "  venv:        ${VENV_DIR:-unknown}"

for ((attempt = 1; attempt <= NUM_RESETS; attempt++)); do
  echo "--- tt-smi -r (${attempt}/${NUM_RESETS}) ---"
  tt-smi -r
  echo "PASS: reset ${attempt}/${NUM_RESETS}"
done

echo "PASS: ${NUM_RESETS} consecutive PCI resets succeeded"
