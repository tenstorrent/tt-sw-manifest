# ttis-golden-versions

Pinned Tenstorrent stack versions (`golden.json`) and CI that validates them the way a customer would install: run [tt-installer](https://github.com/tenstorrent/tt-installer) once, then exercise that same stack on hardware without re-flashing firmware or swapping KMD between steps.

## `golden.json`

| Field | Passed to tt-installer / used by |
|-------|----------------------------------|
| `installer` | tt-installer release tag for `install.sh` + `ttis.sh` (overridable via `INSTALLER_REPO` / `INSTALLER_TAG`) |
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
| **Golden — ttis** (`golden-ttis.yml`) | Push to `main` / `renovate/**`; PRs touching golden files; manual dispatch | Compile `golden.json` → per-distro `.ttis`, test each in Docker, and (on `main`) publish a release |
| **Golden — hardware** (`golden-hw.yml`) | Manual dispatch; Renovate PRs (`renovate/*` branches) | Full HW suite on self-hosted n150 and p150b runners |
| **Renovate** (`renovate.yml`) | Daily schedule + manual dispatch | Bump pins in `golden.json` via Renovate |

Normal pushes and non-Renovate PRs run **golden-ttis only** (no hardware). Hardware runs when you dispatch **Golden — hardware**, or when a Renovate PR is open (both golden-ttis and hw run on those PRs).

### Golden — ttis (compile / test / release)

A matrix of four distros — `ubuntu:22.04`, `ubuntu:24.04`, `debian:13`, `fedora:43` — each in a fresh container as a non-root user:

```
compile-ttis.sh  →  ttis.sh validate  →  golden-install.sh --ttis  →  verify-versions.sh  →  import round-trip
```

`golden.json` is compiled into a per-distro **`.ttis`** file (tt-installer's state-file format), installed via `tt-installer --import-schema`, and verified. These non-hardware `.ttis` files cover the software stack only:

| `.ttis` field | Value |
|---|---|
| `tt_system.tenstorrent-dkms` | `kmd` from `golden.json` |
| `tt_python.tt-smi` / `tt-flash` | `smi` / `flash` from `golden.json` |
| `tt_system.tenstorrent-tools` / `sfpi` | empty (hugepages / sfpi off) |
| `firmware.version` | empty (so importing never triggers a flash) |
| `container_runtime.runtime` | `none` |
| `python_env` | `method: venv`; `python_version: 3.12` on Fedora (see below), else default |

`metal-version` / `metal-upstream-tag` have no place in the `.ttis` schema and stay HW-only concerns.

**Installer release source.** `install.sh` and `ttis.sh` are fetched from a tt-installer **release**, selected by `INSTALLER_REPO` (default `tenstorrent/tt-installer`) and `INSTALLER_TAG` (default `v<golden.json installer>`). The `--import-schema` install path is exercised end-to-end.

> **TEMP (fork pin):** the schema feature (`--import-schema` + `ttis.sh`) and the uv-venv Python provisioning are not yet in an upstream tt-installer release, so `golden-ttis.yml` currently pins `INSTALLER_REPO=knauth/tt-installer`, `INSTALLER_TAG=v3.1.0`, and sets `SKIP_INSTALLER_VERSION_CHECK=1` (that release reports `3.1.0`, which won't match `golden.json`'s `installer` pin). Delete that env block once upstream releases these changes; the scripts then default back to `tenstorrent/tt-installer` at the `installer` pin.

**Fedora / Python.** Fedora 43 ships Python 3.14, which `tt-umd` (a `tt-smi` dependency) has no distribution for. The Fedora `.ttis` pins `python_env.python_version: 3.12`; on import tt-installer creates the venv with `uv venv --python 3.12` (installing `uv` first if absent). The Fedora test container also installs `libatomic` — a runtime dependency of `tt-smi`'s `tt_umd` extension that the minimal image lacks (Ubuntu/Debian already ship it).

On push to `main`, after all four distro jobs pass, the compiled `.ttis` files (plus `golden.json` and a `MANIFEST`) are packaged into `golden.tar.gz` and published as a **date-tagged GitHub Release** (`v2026.06.15`, with a `-N` suffix for same-day re-releases). PRs and `renovate/**` pushes run compile+test but do **not** release.

### Hardware step order

On `tt-ubuntu-2204-n150-stable` and `tt-ubuntu-2204-p150b-stable`:

```
golden-install.sh --hw  →  verify-versions.sh  →  smi-reset.sh  →  ttnn-unit-test.sh
```

Firmware is **not** flashed in CI (`--update-firmware off`). Runners keep their existing device firmware.

## Scripts

All test scripts live in `.github/scripts/`.

### `compile-ttis.sh`

Compiles `golden.json` into a tt-installer `.ttis` state file (schema v1) for one distro. Versions are carried verbatim from `golden.json`; distro fields default to `/etc/os-release`. Emits `python_env.python_version` (defaults to `3.12` on Fedora, so the installer provisions a compatible interpreter via uv). Prints the output path to stdout (logs to stderr).

```bash
compile-ttis.sh [--out <file>] [--distro-id <id>] [--distro-version <ver>] [--family apt|dnf] [--python-version <ver>]
```

### `build-and-test-ttis.sh`

No-hardware orchestrator (run as a non-root user inside a distro): compile → `ttis.sh validate` → `golden-install.sh --ttis` → `verify-versions.sh` → import round-trip.

### `ci-container-bootstrap.sh`

Bootstraps a fresh distro container (installs prereqs, creates an unprivileged user), runs `build-and-test-ttis.sh`, and copies the compiled `.ttis` to `dist/` for upload. Called by `golden-ttis.yml`. On Fedora it also installs `libatomic` (a `tt_umd` runtime dependency the minimal image omits).

### `golden-install.sh`

Downloads tt-installer `install.sh` (and, for `--ttis`, `ttis.sh`) from a release and runs the installer non-interactively. The release defaults to `tenstorrent/tt-installer` at `golden.json`'s `installer` pin; override with `INSTALLER_REPO` / `INSTALLER_TAG` (or set `INSTALLER_URL` / `TTIS_URL` directly).

```bash
golden-install.sh [--hw] [--force-flash]
golden-install.sh --ttis <file>
```

| Flag | Effect |
|------|--------|
| *(none)* | No-hw: KMD + venv (`tt-smi`, `tt-flash`) from `golden.json` flags. No hugepages, no metalium, no container runtime. |
| `--hw` | HW: adds hugepages, metalium release container, Docker/Podman, and pre-pulls `upstream-tests-bh` if `metal-upstream-tag` is set. Requires root. |
| `--force-flash` | Enable firmware flash during install (default: off). |
| `--ttis <file>` | No-hw install driven by a compiled `.ttis` via `--import-schema` (version pins, Python version, etc. come from the file, not flags). Fetches both `install.sh` and `ttis.sh` from the release. Honors `INSTALL_EXTRA_ARGS` for extra installer flags. Mutually exclusive with `--hw`. |

Records the installer venv path to `/tmp/tenstorrent-installer-venv.path`.

### `verify-versions.sh`

Activates the installer Python venv (`~/.tenstorrent-venv`, or `VENV_DIR` / path file) and checks:

- `installer`, `kmd` (via `dpkg-query` / `rpm` on `tenstorrent-dkms`), `smi`, `flash` match `golden.json`
- `tt-smi -v`, `tt-flash -v`, `tt-smi -h`, `tt-flash -h` smoke tests pass

Set `SKIP_INSTALLER_VERSION_CHECK=1` to report (not fail) the installer row when installing from a release whose version differs from the `installer` pin (e.g. the fork pin above). The script prints each CLI's raw output and exit code, so a failing `tt-smi`/`tt-flash` shows its traceback and a clear `FAIL` row instead of aborting silently.

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

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).

Copyright (c) 2025-2026 Tenstorrent AI ULC
