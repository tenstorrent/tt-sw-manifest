# ttis-golden-versions

Pinned Tenstorrent stack versions (`golden.json`) and CI that validates them the way a customer would install: run [tt-installer](https://github.com/tenstorrent/tt-installer) once, then exercise that same stack on hardware without re-flashing firmware or swapping KMD between steps.

## `golden.json`

| Field | Passed to tt-installer / used by |
|-------|----------------------------------|
| `installer` | tt-installer release used to download `install.sh` |
| `kmd` | `--kmd-version` → `tenstorrent-dkms` |
| `smi` | `--smi-version` → `tt-smi` in installer venv |
| `flash` | `--flash-version` → `tt-flash` in installer venv |
| `firmware` | `--fw-version` (flash off by default in CI) |
| `metal-version` | `--metalium-image-tag` → `tt-metalium-ubuntu-22.04-release-amd64` (HW install + ttnn unit test) |
| `metal-upstream-tag` | `upstream-tests-bh` image tag (reserved; upstream test not in CI yet) |

[Renovate](renovate.json) opens grouped PRs when these pins change.

## CI workflows

Three workflows under `.github/workflows/`:

| Workflow | When it runs | What it does |
|----------|--------------|--------------|
| **Golden — no hardware** (`golden-no-hw.yml`) | Push to `main` / `renovate/**`; PRs touching golden files; manual dispatch | Install + verify inside `ubuntu:22.04` Docker on `ubuntu-latest` |
| **Golden — hardware** (`golden-hw.yml`) | Manual dispatch; Renovate PRs (`renovate/*` branches) | Full HW suite on self-hosted n150 and p150b runners |
| **Renovate** (`renovate.yml`) | Daily schedule + manual dispatch | Bump pins in `golden.json` via Renovate |

Normal pushes and non-Renovate PRs run **no-hardware only**. Hardware runs when you dispatch **Golden — hardware**, or when a Renovate PR is open (both no-hw and hw run on those PRs).

### Hardware step order

On `tt-ubuntu-2204-n150-stable` and `tt-ubuntu-2204-p150b-stable`:

```
golden-install.sh --hw  →  verify-versions.sh  →  smi-reset.sh  →  ttnn-unit-test.sh
```

Firmware is **not** flashed in CI (`--update-firmware off`). Runners keep their existing device firmware.

### No-hardware step order

Inside a fresh `ubuntu:22.04` container as a non-root user:

```
golden-install.sh  →  verify-versions.sh
```

## Scripts

All test scripts live in `.github/scripts/`.

### `golden-install.sh`

Downloads tt-installer `install.sh` at the pinned `installer` version and runs it non-interactively against `golden.json`.

```bash
golden-install.sh [--hw] [--force-flash]
```

| Flag | Effect |
|------|--------|
| *(none)* | No-hw: KMD + venv (`tt-smi`, `tt-flash`). No hugepages, no metalium, no container runtime. |
| `--hw` | HW: adds hugepages, metalium release container, Docker/Podman, and pre-pulls `upstream-tests-bh` if `metal-upstream-tag` is set. Requires root. |
| `--force-flash` | Enable firmware flash during install (default: off). |

Records the installer venv path to `/tmp/tenstorrent-installer-venv.path`.

### `verify-versions.sh`

Activates the installer Python venv (`~/.tenstorrent-venv`, or `VENV_DIR` / path file) and checks:

- `installer`, `kmd` (via `dpkg-query` / `rpm` on `tenstorrent-dkms`), `smi`, `flash` match `golden.json`
- `tt-smi -v`, `tt-flash -v`, `tt-smi -h`, `tt-flash -h` smoke tests pass

### `smi-reset.sh`

Runs `tt-smi -r` (PCI reset all devices) **10 times** using the installer venv. Configurable via `NUM_RESETS`.

### `ttnn-unit-test.sh`

Pulls `ghcr.io/tenstorrent/tt-metal/tt-metalium-ubuntu-22.04-release-amd64:<metal-version>` and runs `tests/metalium-workload.py` in a privileged container with `/dev/tenstorrent` and hugepages mounted from the host. Does not re-install KMD or flash firmware.

### `metal-upstream.sh`

Runs `upstream-tests-bh` container tests via `run_upstream_tests_vanilla.sh`. **Not currently enabled in CI** (workflow step is commented out). The script remains for manual use; set `METAL_TARGET` (default `blackhole_no_models`) and ensure `metal-upstream-tag` is set in `golden.json`.

## Test workload

`tests/metalium-workload.py` — opens device 0 with **ttnn**, runs a small bfloat16 tensor add, closes the device. Mounted read-only into the metalium container at `/metalium-workload.py`.

## Local run

`complete_installer_test.sh` mirrors CI and prints a pass/fail summary:

```bash
# Hardware (root): golden-install.sh --hw → verify-versions.sh → smi-reset.sh → ttnn-unit-test.sh
sudo ./complete_installer_test.sh

# No device: golden-install.sh → verify-versions.sh
./complete_installer_test.sh --no-hw

# Re-run tests after a previous install
sudo ./complete_installer_test.sh --skip-install

# Install only
sudo ./complete_installer_test.sh --install-only

# Force firmware flash during install
sudo ./complete_installer_test.sh --force-flash
```

## Notes

- **Hugepages:** HW install uses `--install-hugepages`. If ttnn test fails with missing `/dev/hugepages-1G`, re-run install or reboot once after first setup (CI uses `--reboot-option never`).
- **Self-hosted runners** may log `sudo: unable to resolve host ubuntu` when the hostname is missing from `/etc/hosts`. Harmless. To silence: `echo "127.0.0.1 ubuntu" | sudo tee -a /etc/hosts`
- **Upstream image tags** on `upstream-tests-bh` are CI dev tags (e.g. `v0.71.0-dev20260516-…`), not the same as release `metal-version` tags on the metalium image.
