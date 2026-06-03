# ttis-golden-versions

Golden version pins (`golden.json`) and CI that mirrors a **customer install**: run [tt-installer](https://github.com/tenstorrent/tt-installer) once on each runner, then exercise that stack on real hardware without re-installing or swapping KMD/firmware between test steps.

## How CI uses the installer

Both jobs start from the same pins in `golden.json`. [tt-installer](https://github.com/tenstorrent/tt-installer) `install.sh` is downloaded at the pinned `installer` version and invoked non-interactively with component versions (`kmd`, `smi`, `flash`, `firmware`, and on hardware `metal-version`).

| What the installer sets up | Used by later steps |
|----------------------------|---------------------|
| `tenstorrent-dkms` (KMD) | Host driver for all HW tests |
| Python venv at `~/.tenstorrent-venv` (`--python-choice new-venv`) | `tt-smi`, `tt-flash` via `activate-installer-python.sh` |
| Firmware flash (HW only, `--update-firmware force`) | Device firmware before smi/metal |
| Hugepages (`--install-hugepages` via tenstorrent-tools) | Host `/dev/hugepages-1G` for metal unit + upstream containers |
| `~/.local/bin/tt-metalium` + release container pull (HW only) | Metal unit test image |
| Docker/Podman (`--install-container-runtime`) | Metal unit + upstream containers |

**Customer-install model on hardware:** one root install (`golden-install-hw.sh`), then verify → smi stress → metal tests reuse the host KMD, firmware, and installer venv. Metal steps run **inside** GHCR containers but bind `/dev/tenstorrent` and hugepages from the host — they do not re-flash or replace KMD.

**No-hardware job:** runs inside an `ubuntu:22.04` container as a normal user; install skips firmware flash and metalium (`golden-install.sh`), then only verifies CLI versions.

## CI jobs and step order

| Job | Workflow | Runners | Steps (in order) |
|-----|----------|---------|------------------|
| **No hardware** | `golden-no-hw.yml` | `ubuntu-latest` (Docker `ubuntu:22.04`) | `golden-install.sh` → `verify-golden-versions.sh` |
| **Hardware** | `golden-hw.yml` | `tt-ubuntu-2204-n150-stable`, `tt-ubuntu-2204-p150b-stable` | `golden-install-hw.sh` → `verify-golden-versions.sh` → `golden-smi-reset-stress.sh` → `golden-metal-unit-test.sh` → `golden-metal-upstream.sh` |

Orchestrator: `.github/workflows/golden.yml` (push to `main` / `renovate/**`, PRs touching golden files, `workflow_dispatch`).

Each HW test script prints a **version banner** at the start (golden pins + what it is about to run) via `golden-echo-test-versions.sh`.

## Tests and scripts

| Name | Type | CI step | What it does |
|------|------|---------|--------------|
| **`golden-install.sh`** | Script | No-hw: install | Downloads tt-installer `install.sh`, installs KMD + `tt-smi` / `tt-flash` into a new venv. Firmware flash **off**, metalium container **off**, no container runtime. Records venv path in `/tmp/tenstorrent-installer-venv.path`. |
| **`golden-install-hw.sh`** | Script | HW: install | Same installer flow on a self-hosted runner as **root**: KMD, venv, **`--update-firmware force`**, metalium release container (`--metalium-image-tag` from `metal-version`). Also **pulls** `upstream-tests-bh` (not done by installer) for the upstream step. |
| **`verify-golden-versions.sh`** | Test | Both jobs | Sources installer venv; prints version table; checks installed `installer` / `kmd` / `smi` / `flash` match `golden.json`; runs `tt-smi` and `tt-flash` **smoke** (`-v` version match, `-h` help output). |
| **`golden-smi-reset-stress.sh`** | Test | HW only | Runs **`tt-smi -r`** (PCI reset all devices) **10×** using installer venv `tt-smi`. Stresses reset path after firmware/KMD install. |
| **`tests/metalium-workload.py`** | Test (Python) | HW: metal unit | Opens device 0 via **ttnn**, runs a small bfloat16 tensor add. Copied from tt-installer’s metalium workload pattern. |
| **`golden-metal-unit-test.sh`** | Script | HW: metal unit | Pulls **release** image `tt-metalium-ubuntu-22.04-release-amd64:<metal-version>`, `docker run --privileged` with `/dev/tenstorrent`, hugepages, and workload mounted read-only; entrypoint `python3 /metalium-workload.py`. Enabled on all boards in `golden-metal-boards.json`. |
| **`golden-metal-upstream.sh`** | Test | HW: metal upstream | Pulls **`upstream-tests-bh:<metal-upstream-tag>`** when set, runs `run_upstream_tests_vanilla.sh` on p150b (`blackhole_no_models`). **Skipped on n150** or when `metal-upstream-tag` is unset (no release tag on upstream image). Optional patches (e.g. determinism on p150b). |
| **`activate-installer-python.sh`** | Helper | (sourced) | Resolves installer venv (`VENV_DIR`, `/tmp/tenstorrent-installer-venv.path`, or `/root/.tenstorrent-venv`) and prepends `bin` to `PATH` so **`sudo` steps still use installer `tt-smi`**. |
| **`golden-echo-test-versions.sh`** | Helper | (sourced) | Prints test banners and golden pin summary before each step. |
| **`golden-metal-images.sh`** | Helper | (sourced) | Builds GHCR refs from `metal-version` (normalizes `v` prefix). |
| **`golden-metal-board.sh`** | Helper | (sourced) | Matches `GOLDEN_RUNNER_LABEL` / `GITHUB_RUNNER_NAME` prefix to `.github/golden-metal-boards.json` (unit vs upstream, `metal-target`, patches). |

## Container images

| Pin in `golden.json` | Image | Used for |
|----------------------|-------|----------|
| **`metal-version`** (e.g. `v0.71.2`) | `tt-metalium-ubuntu-22.04-release-amd64:<tag>` | Customer install + metal unit test (`tests/metalium-workload.py`) |
| **`metal-upstream-tag`** (optional) | `upstream-tests-bh:<tag>` | Metal upstream on p150b only |

Release tags like `v0.71.2` exist on the **metalium release** image. **`upstream-tests-bh` does not use those tags** — GHCR only has CI dev tags (e.g. `v0.71.0-dev20260516-2-ga8aa13392b0`). If `metal-upstream-tag` is omitted, the upstream step is **skipped** (install, verify, smi stress, and unit test still run).

To enable upstream, set `metal-upstream-tag` to a tag that exists on GHCR (list with the registry API or `skopeo list-tags docker://ghcr.io/tenstorrent/tt-metal/upstream-tests-bh`). Align it manually with the `metal-version` line you care about.

### Board-specific metal behavior

| Runner label | Metal unit | Metal upstream |
|--------------|------------|----------------|
| `tt-ubuntu-2204-n150-stable` | Yes | No (skip: BH upstream only) |
| `tt-ubuntu-2204-p150b-stable` | Yes | Yes — `blackhole_no_models` |

Config: `.github/golden-metal-boards.json`.

## Pins (`golden.json`)

| Field | Role |
|-------|------|
| `installer` | tt-installer release used to fetch `install.sh` |
| `kmd`, `smi`, `flash`, `firmware` | Passed to tt-installer (`--kmd-version`, etc.) |
| `metal-version` | tt-metalium **release** container tag (installer + unit test) |
| `metal-upstream-tag` | Optional `upstream-tests-bh` dev tag; omit to skip upstream on p150b |

## Logs

Self-hosted runners may print `sudo: unable to resolve host ubuntu` on every `sudo` call when the hostname is not in `/etc/hosts`. That warning is harmless; steps still pass. See `.github/workflows/golden-hw.yml`.

## Local test run

From a clone of this repo, run the same steps as CI and get a terminal summary:

```bash
# Hardware (root): install + verify + smi stress + metal tests
sudo ./complete_installer_test.sh --runner-label tt-ubuntu-2204-p150b-stable

# No device: install + verify only
./complete_installer_test.sh --no-hw

# Tests only (after install)
sudo ./complete_installer_test.sh --skip-install --runner-label tt-ubuntu-2204-n150-stable
```

See `./complete_installer_test.sh --help` for options.

**Local full upstream only** (install without firmware flash, all `blackhole_no_models` upstream suites — no smi stress / unit test):

```bash
# Fresh pull of container images + install (with hugepages) + upstream
sudo ./local_bh_upstream_tests.sh --remove-images

# Normal run (keeps existing docker images)
sudo ./local_bh_upstream_tests.sh

# Upstream only after install / reboot
sudo ./local_bh_upstream_tests.sh --skip-install
```

Remove images manually (tags from `golden.json`):

```bash
docker rmi ghcr.io/tenstorrent/tt-metal/upstream-tests-bh:v0.71.0-dev20260516-2-ga8aa13392b0
docker rmi ghcr.io/tenstorrent/tt-metal/tt-metalium-ubuntu-22.04-release-amd64:v0.71.2
```

**Hugepages:** HW install uses `--install-hugepages` (tt-installer default). If metal tests fail with missing `/dev/hugepages-1G`, re-run install or reboot once after the first hugepages setup (`--reboot-option never` in CI avoids auto-reboot).
