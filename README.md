# tt-sw-manifest

Pinned Tenstorrent stack versions (`golden.json`) and CI that validates them the way a customer would install: run [tt-installer](https://github.com/tenstorrent/tt-installer) once, then exercise that same stack on hardware without re-flashing firmware or swapping KMD between steps.

## Important Notice

**This is a staging and testing repository only.** It is used internally by Tenstorrent for validating golden versions of the Tenstorrent software stack. This repository is provided as-is for reference purposes.

**Please do not open issues or pull requests in this repository.** They will be closed without review. For issues with specific Tenstorrent software components, please refer to the appropriate component repositories.

## `golden.json`

| Field | Passed to tt-installer / used by |
|-------|----------------------------------|
| `installer` | tt-installer release tag for `install.sh` + `ttis.sh` (overridable via `INSTALLER_REPO` / `INSTALLER_TAG`) |
| `kmd` | `--kmd-version` → `tenstorrent-dkms` |
| `smi` | `--smi-version` → `tt-smi` in installer venv |
| `flash` | `--flash-version` → `tt-flash` in installer venv |
| `sfpi` | `--sfpi-version` → `sfpi` (from [tenstorrent/sfpi](https://github.com/tenstorrent/sfpi)) |
| `hugepages` | `--systools-version` → `tenstorrent-tools` (from [tenstorrent/tt-system-tools](https://github.com/tenstorrent/tt-system-tools), installed with hugepages) |
| `firmware` | `--fw-version`; never flashed in CI, but recorded in the exported `.ttis` as assumed-flashed |
| `metal-version` | `--metalium-image-tag` → `tt-metalium-ubuntu-22.04-release-amd64` (HW install + ttnn unit test) |
| `metal-upstream-tag` | `upstream-tests-bh` image tag (reserved; upstream test not in CI yet) |
| `test-sha` | **Release artifact only** — commit on `main` that golden-ttis and golden-hw passed when the release was cut (not present in the repo copy of `golden.json`) |

[Renovate](renovate.json) opens grouped PRs when these pins change.

## CI workflows

Four workflows under `.github/workflows/`:

| Workflow | When it runs | What it does |
|----------|--------------|--------------|
| **Golden — ttis** (`golden-ttis.yml`) | Push to `main` / `renovate/**`; PRs touching golden files; manual dispatch | Install the `golden.json` stack in each distro container, export a per-distro `.ttis`, and verify it |
| **Golden — hardware** (`golden-hw.yml`) | Push to `main` / `renovate/**`; PRs touching golden files; manual dispatch; called by release workflow | Full HW suite on self-hosted n150 and p150b runners |
| **Golden — release** (`golden-release.yml`) | Manual dispatch from `main` only | Re-run no-hw + HW validation, then publish a date-tagged GitHub Release |
| **Renovate** (`renovate.yml`) | Daily schedule + manual dispatch | Bump pins in `golden.json` via Renovate |

Pushes to `main` / `renovate/**` and PRs touching golden files run **both** golden-ttis and golden-hw.

### Golden — ttis (install / export / test)

A matrix of four distros — `ubuntu:22.04`, `ubuntu:24.04`, `debian:13`, `fedora:43` — each in a fresh container as a non-root user:

```
golden-install.sh --export  →  ttis.sh validate  →  verify-versions.sh  →  import round-trip
```

`tt-installer` installs the full host software stack at `golden.json` pins, then `--export-schema` captures the **actually-installed** versions into a per-distro **`.ttis`** file (tt-installer's state-file format). That exported file — not a hand-built one — is what gets released, so the recorded versions are the ones the install really produced:

| `.ttis` field | Value |
|---|---|
| `tt_system.tenstorrent-dkms` | installed `tenstorrent-dkms` (matched against `kmd`) |
| `tt_system.tenstorrent-tools` | installed `tenstorrent-tools` (matched against `tools`) |
| `tt_system.sfpi` | installed `sfpi` (matched against `sfpi`) |
| `tt_python.tt-smi` / `tt-flash` | installed `tt-smi` / `tt-flash` (matched against `smi` / `flash`) |
| `firmware.version` | `firmware` from `golden.json`, **recorded as assumed-flashed** — CI never flashes (no device), but the value is written so importing on real hardware flashes to the pin¹ |
| `container_runtime.runtime` | `none` |
| `python_env` | `method: venv`; `location` blanked for portability; `python_version: 3.12` on Fedora (see below), else empty |

¹ Firmware can't be flashed in the no-hardware matrix, so the export naturally records it empty; `golden-install.sh --export` then injects the `golden.json` value back in. Until a real CI fleet flashes and exports for real, the golden trusts the pin.

`metal-version` / `metal-upstream-tag` have no place in the `.ttis` schema and stay HW-only concerns.

**Installer release source.** `install.sh` and `ttis.sh` are fetched from a tt-installer **release**, selected by `INSTALLER_REPO` (default `tenstorrent/tt-installer`) and `INSTALLER_TAG` (default `v<golden.json installer>`). The `--export-schema` install path produces the released file; the import round-trip then confirms that file is consumable via `ttis.sh` / `--import-schema`.

**Fedora / Python.** Fedora 43 ships Python 3.14, which `tt-umd` (a `tt-smi` dependency) has no distribution for. The Fedora `.ttis` pins `python_env.python_version: 3.12`; on import tt-installer creates the venv with `uv venv --python 3.12` (installing `uv` first if absent). The Fedora test container also installs `libatomic` — a runtime dependency of `tt-smi`'s `tt_umd` extension that the minimal image lacks (Ubuntu/Debian already ship it).

Dispatch **Golden — release** from `main` after no-hw and HW validation pass. The workflow re-runs both suites, then publishes `golden.json` (with `test-sha` set to the dispatch commit) and the four per-distro `.ttis` files as a **date-tagged GitHub Release** (`v2026.06.15`, with a `-N` suffix for same-day re-releases). Routine CI (push/PR) does **not** publish a release.

### Hardware step order

On `tt-ubuntu-2204-n150-stable` and `tt-ubuntu-2204-p150b-stable`:

```
golden-install.sh --hw  →  verify-versions.sh  →  smi-reset.sh  →  ttnn-unit-test.sh
```

Firmware is **not** flashed in CI (`--update-firmware off`). Runners keep their existing device firmware.

## Scripts

All test scripts live in `.github/scripts/`.

### `build-and-test-ttis.sh`

No-hardware orchestrator (run as a non-root user inside a distro): `golden-install.sh --export` → `ttis.sh validate` → `verify-versions.sh` → import round-trip. The exported `golden/<distro>.ttis` is the release artifact.

### `ci-container-bootstrap.sh`

Bootstraps a fresh distro container (installs prereqs, creates an unprivileged user), runs `build-and-test-ttis.sh`, and copies the exported `.ttis` to `dist/` for upload. Called by `golden-ttis.yml`. On Fedora it also installs `libatomic` (a `tt_umd` runtime dependency the minimal image omits).

### `golden-install.sh`

Downloads tt-installer `install.sh` (and, for `--ttis` / `--export`, `ttis.sh`) from a release and runs the installer non-interactively. The release defaults to `tenstorrent/tt-installer` at `golden.json`'s `installer` pin; override with `INSTALLER_REPO` / `INSTALLER_TAG` (or set `INSTALLER_URL` / `TTIS_URL` directly).

```bash
golden-install.sh [--hw] [--force-flash]
golden-install.sh --ttis <file>
golden-install.sh --export <file>
```

| Flag | Effect |
|------|--------|
| *(none)* | No-hw: KMD + venv (`tt-smi`, `tt-flash`) from `golden.json` flags. No hugepages/sfpi, no metalium, no container runtime. |
| `--hw` | HW: adds hugepages, metalium release container, Docker/Podman, and pre-pulls `upstream-tests-bh` if `metal-upstream-tag` is set. Requires root. |
| `--force-flash` | Enable firmware flash during install (default: off). |
| `--ttis <file>` | No-hw install driven by a compiled `.ttis` via `--import-schema` (version pins, Python version, etc. come from the file, not flags). Fetches both `install.sh` and `ttis.sh` from the release. Honors `INSTALL_EXTRA_ARGS` for extra installer flags. Mutually exclusive with `--hw`. |
| `--export <file>` | No-hw install of the **full** host stack (KMD + `tenstorrent-tools`/hugepages + `sfpi` + venv) at `golden.json` pins, then `--export-schema` writes the installed versions to `<file>`. Afterward, firmware is recorded from `golden.json` (assumed-flashed; never actually flashed) and `python_env.location` is blanked for portability. Mutually exclusive with `--hw` / `--ttis`. |

Records the installer venv path to `/tmp/tenstorrent-installer-venv.path`.

### `verify-versions.sh`

Activates the installer Python venv (`~/.tenstorrent-venv`, or `VENV_DIR` / path file) and checks:

- `installer`, `kmd` (via `dpkg-query` / `rpm` on `tenstorrent-dkms`), `smi`, `flash` match `golden.json`
- `sfpi` and `tools` (`tenstorrent-tools`) match `golden.json` **when installed** — checked on the no-hw export run; reported as `SKIP` on paths that don't install them (e.g. HW)
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

## Contributing

This is a staging and testing repository only. Please do not open issues or submit pull requests. See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

For issues with Tenstorrent software components, please refer to the appropriate component repositories.

## License

This project is licensed under the Apache License, Version 2.0, except where specified. See the following files for complete licensing information:

- [LICENSE](LICENSE) — Overall license for this project
- [LICENSE_understanding.txt](LICENSE_understanding.txt) — Additional clarifications about the Apache 2.0 license application
- [NOTICE](NOTICE) — Copyright and attribution notices

Copyright (c) 2025-2026 Tenstorrent USA, Inc.
