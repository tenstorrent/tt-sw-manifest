# ttis-golden-versions

Golden version pins (`golden.json`) and CI that mirrors a **customer install**: run [tt-installer](https://github.com/tenstorrent/tt-installer) once, then exercise the stack on real hardware.

## What CI does

| Job | Runners | Flow |
|-----|---------|------|
| **No hardware** | `ubuntu-latest` (container) | `golden-install.sh` → `verify-golden-versions.sh` |
| **Hardware** | `tt-ubuntu-2204-n150-stable`, `tt-ubuntu-2204-p150b-stable` | `golden-install-hw.sh` (KMD, firmware, tt-smi, tt-flash, **tt-metalium** container) → version verify → `tt-smi -r` ×10 → **metal upstream** tests |

Hardware jobs do **not** rebuild firmware or re-run tt-installer in later steps. Metal upstream tests are adapted from [tt-system-firmware `metal.yml`](https://github.com/tenstorrent/tt-system-firmware/blob/main/.github/workflows/metal.yml) but skip artifact flash / KMD swap; they use the image recorded at install time (`metal-upstream-image` in `golden.json`).

## Pins (`golden.json`)

| Field | Role |
|-------|------|
| `installer`, `kmd`, `smi`, `flash`, `firmware` | Passed to tt-installer |
| `metalium-image-tag` | `tt-metalium` release container tag (installer) |
| `metal-upstream-image` | tt-metal `upstream-tests-bh` image for pytest/C++ upstream suites |

## Metal upstream on hardware

- Board → runner mapping: `.github/golden-metal-boards.json`
- **p150b**: `blackhole_no_models` (no HF weights; matches syseng runners)
- **n150**: skipped (Wormhole; BH upstream suites do not apply)

To add Llama / multi-device targets, extend `golden-metal-boards.json` and mount model paths like tt-system-firmware does.

## Logs

Self-hosted runners may print `sudo: unable to resolve host ubuntu` — harmless; see comment in `.github/workflows/golden-hw.yml`.
