#!/usr/bin/env python3
# SPDX-FileCopyrightText: © 2025-2026 Tenstorrent AI ULC
# SPDX-License-Identifier: Apache-2.0
#
# Smoke test for the tt-metalium container on a Tenstorrent device.
# Mirrors tt-installer/tests/metalium-workload.py (June's hosted N150 metal test).
# Run via: docker run ... --entrypoint python3 <image> /metalium-workload.py
import ttnn

device = ttnn.open_device(device_id=0)
print(f"Opened device: {device}")

a = ttnn.full((1, 1, 32, 32), 1.0, dtype=ttnn.bfloat16, layout=ttnn.TILE_LAYOUT, device=device)
b = ttnn.add(a, a)
print(f"Tensor add: shape={b.shape}")

ttnn.close_device(device)
print("✓ tt-metalium workload passed")
