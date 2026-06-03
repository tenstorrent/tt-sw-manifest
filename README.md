# ttis-golden-versions

Golden version pins (`golden.json`) and CI that mirrors a **customer install**: run [tt-installer](https://github.com/tenstorrent/tt-installer) once on each runner, then exercise that stack on real hardware without re-installing or swapping KMD/firmware between test steps.

## How CI uses the installer

Both jobs start from the same pins in `golden.json`. [tt-installer](https://github.com/tenstorrent/tt-installer) `install.sh` is downloaded at the pinned `installer` version and invoked non-interactively with component versions (`kmd`, `smi`, `flash`, `firmware`, and on hardware `metal-version`).

| What the installer sets up | Used by later steps |
|----------------------------|---------------------|
| `tenstorrent-dkms` (KMD) | Host driver for all HW tests |
| Python venv at `~/.tenstorrent-venv` (`--python-choice new-venv`) | `tt-smi`, `tt-flash` via `activate-installer-python.sh` |
| Firmware flash (HW only, `--update-firmware force`) | Device firmware before smi/metal |
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
| **`golden-metal-upstream.sh`** | Test | HW: metal upstream | Pulls **`upstream-tests-bh:<metal-version>`**, runs `run_upstream_tests_vanilla.sh` inside the container with host devices mounted. Target from board config (e.g. `blackhole_no_models` on p150b). **Skipped on n150** (Wormhole; upstream image is Blackhole-only). Optional patches (e.g. disable determinism interval on p150b). |
| **`activate-installer-python.sh`** | Helper | (sourced) | Resolves installer venv (`VENV_DIR`, `/tmp/tenstorrent-installer-venv.path`, or `/root/.tenstorrent-venv`) and prepends `bin` to `PATH` so **`sudo` steps still use installer `tt-smi`**. |
| **`golden-echo-test-versions.sh`** | Helper | (sourced) | Prints test banners and golden pin summary before each step. |
| **`golden-metal-images.sh`** | Helper | (sourced) | Builds GHCR refs from `metal-version` (normalizes `v` prefix). |
| **`golden-metal-board.sh`** | Helper | (sourced) | Matches `GOLDEN_RUNNER_LABEL` / `GITHUB_RUNNER_NAME` prefix to `.github/golden-metal-boards.json` (unit vs upstream, `metal-target`, patches). |

## Container images (`metal-version`)

One pin in `golden.json` (e.g. `v0.71.2`) drives two images via `golden-metal-images.sh`:

| Image | Pulled by | Used in |
|-------|-----------|---------|
| `ghcr.io/tenstorrent/tt-metal/tt-metalium-ubuntu-22.04-release-amd64:<tag>` | **tt-installer** (HW install) + metal unit script | `golden-metal-unit-test.sh` |
| `ghcr.io/tenstorrent/tt-metal/upstream-tests-bh:<tag>` | **`golden-install-hw.sh`** only (installer does not pull this) | `golden-metal-upstream.sh` |

If `upstream-tests-bh` is not published at that tag on GHCR, the upstream step fails until the tag exists.

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
| `metal-version` | tt-metal container tag for **both** release and upstream images |

## Logs

Self-hosted runners may print `sudo: unable to resolve host ubuntu` on every `sudo` call when the hostname is not in `/etc/hosts`. That warning is harmless; steps still pass. See `.github/workflows/golden-hw.yml`.
