# ttis-golden-versions

Golden version pins (`golden.json`) and CI that mirrors a **customer install**: run [tt-installer](https://github.com/tenstorrent/tt-installer) once, then exercise the stack on real hardware.

## What CI does

| Job | Runners | Flow |
|-----|---------|------|
| **No hardware** | `ubuntu-latest` (container) | `golden-install.sh` → `verify-golden-versions.sh` |
| **Hardware** | `tt-ubuntu-2204-n150-stable`, `tt-ubuntu-2204-p150b-stable` | install → verify → `tt-smi -r` ×10 → **metal unit test** → **metal upstream** (p150b only) |

Each HW test step prints a **version banner** at the start (golden pins + what it is about to run).

## Who pulls which container image?

One pin: **`metal-version`** (e.g. `v0.71.2`). Scripts build both GHCR refs in `golden-metal-images.sh`:

| Image | Pulled by |
|-------|-----------|
| `tt-metalium-ubuntu-22.04-release-amd64:<metal-version>` | **tt-installer** + metal unit test |
| `upstream-tests-bh:<metal-version>` | **golden-install-hw.sh** only (not installer) |

If `upstream-tests-bh` is not published at that tag yet, CI may fail on the upstream step until GHCR catches up.

### Metal tests

| Step | What it validates |
|------|-------------------|
| **Metal unit test** | Customer release container + `ttnn` smoke (`tests/metalium-workload.py`) |
| **Metal upstream** | `run_upstream_tests_vanilla.sh` on p150b (`blackhole_no_models`). Skipped on n150. |

## Pins (`golden.json`)

| Field | Role |
|-------|------|
| `installer`, `kmd`, `smi`, `flash`, `firmware` | Passed to tt-installer |
| `metal-version` | tt-metal release (both container images derive from this tag) |

## Runner labels

Use `GOLDEN_RUNNER_LABEL` from the workflow matrix. Board config: `.github/golden-metal-boards.json`.

## Logs

Self-hosted runners may print `sudo: unable to resolve host ubuntu` — harmless; see `.github/workflows/golden-hw.yml`.
