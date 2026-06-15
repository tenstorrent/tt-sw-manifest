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
| **Golden — ttis** (`golden-ttis.yml`) | Push to `main` / `renovate/**`; PRs touching golden files; manual dispatch | Compile `golden.json` → per-distro `.ttis`, test each in Docker, and (on `main`) publish a release |
| **Golden — hardware** (`golden-hw.yml`) | Manual dispatch; Renovate PRs (`renovate/*` branches) | Full HW suite on self-hosted n150 and p150b runners |
| **Renovate** (`renovate.yml`) | Daily schedule + manual dispatch | Bump pins in `golden.json` via Renovate |

Normal pushes and non-Renovate PRs run **golden-ttis only** (no hardware). Hardware runs when you dispatch **Golden — hardware**, or when a Renovate PR is open (both golden-ttis and hw run on those PRs).

### Golden — ttis (compile / test / release)

For each distro (`ubuntu:22.04`, `ubuntu:24.04`, `debian:13`, `fedora:43`), in a fresh container as a non-root user:

```
compile-ttis.sh  →  ttis.sh validate  →  golden-install.sh --ttis  →  verify-versions.sh  →  import round-trip
```

`golden.json` is compiled into a per-distro **`.ttis`** file (tt-installer's state-file format), which is then installed via `tt-installer --import-schema` and verified. These non-hardware `.ttis` files cover the software stack only — `tenstorrent-tools` (hugepages), `sfpi`, firmware flashing, and the container runtime are all disabled (`firmware.version` is empty so importing never triggers a flash). `metal-version` / `metal-upstream-tag` have no place in the `.ttis` schema and stay HW-only concerns.

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

Compiles `golden.json` into a tt-installer `.ttis` state file (schema v1) for one distro. Versions are carried verbatim from `golden.json`; distro fields default to `/etc/os-release`. Prints the output path to stdout (logs to stderr).

```bash
compile-ttis.sh [--out <file>] [--distro-id <id>] [--distro-version <ver>] [--family apt|dnf]
```

### `build-and-test-ttis.sh`

No-hardware orchestrator (run as a non-root user inside a distro): compile → `ttis.sh validate` → `golden-install.sh --ttis` → `verify-versions.sh` → import round-trip.

### `ci-container-bootstrap.sh`

Bootstraps a fresh distro container (installs prereqs, creates an unprivileged user), runs `build-and-test-ttis.sh`, and copies the compiled `.ttis` to `dist/` for upload. Called by `golden-ttis.yml`.

### `golden-install.sh`

Downloads tt-installer `install.sh` at the pinned `installer` version and runs it non-interactively.

```bash
golden-install.sh [--hw] [--force-flash]
golden-install.sh --ttis <file>
```

| Flag | Effect |
|------|--------|
| *(none)* | No-hw: KMD + venv (`tt-smi`, `tt-flash`) from `golden.json` flags. No hugepages, no metalium, no container runtime. |
| `--hw` | HW: adds hugepages, metalium release container, Docker/Podman, and pre-pulls `upstream-tests-bh` if `metal-upstream-tag` is set. Requires root. |
| `--force-flash` | Enable firmware flash during install (default: off). |
| `--ttis <file>` | No-hw install driven by a compiled `.ttis` via `--import-schema` (version pins come from the file, not flags). Also fetches `ttis.sh` from the pinned release. Mutually exclusive with `--hw`. |

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
