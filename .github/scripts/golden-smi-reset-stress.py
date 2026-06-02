#!/usr/bin/env python3
# SPDX-FileCopyrightText: © 2025 Tenstorrent Inc.
# SPDX-License-Identifier: Apache-2.0
#
# PCI reset stress test using tt-smi from the golden stack install.
# Logic matches tenstorrent/tt-smi tests/test_reset.py::test_pci_reset_all_devices_stress.

import os
import sys

NUM_RESETS = int(os.environ.get("NUM_RESETS", "10"))


def main() -> int:
    from tt_umd import PCIDevice
    from tt_smi.tt_smi_backend import pci_board_reset

    def enumerate_devices() -> list[int]:
        return PCIDevice.enumerate_devices()

    devices = enumerate_devices()
    if not devices:
        print(
            "FAIL: no Tenstorrent PCI devices found (PCIDevice.enumerate_devices empty)",
            file=sys.stderr,
        )
        return 1

    print(f"Found {len(devices)} device(s) for reset stress test (UMD)")
    for attempt in range(1, NUM_RESETS + 1):
        pci_board_reset(devices, reinit=True, use_umd=True, print_status=False)
        post_reset_devices = enumerate_devices()
        if len(post_reset_devices) != len(devices):
            print(
                f"FAIL: reset {attempt}/{NUM_RESETS}: "
                f"device count {len(post_reset_devices)} != {len(devices)}",
                file=sys.stderr,
            )
            return 1
        print(f"PASS: reset {attempt}/{NUM_RESETS} ({len(post_reset_devices)} devices)")

    print(f"PASS: {NUM_RESETS} consecutive PCI resets succeeded")
    return 0


if __name__ == "__main__":
    sys.exit(main())
