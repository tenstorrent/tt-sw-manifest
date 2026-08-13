# tt-sw-manifest

**Golden stack** for Tenstorrent software. [`golden.json`](golden.json) pins a set of component versions; CI installs that combo using [tt-installer](https://github.com/tenstorrent/tt-installer) and runs the full validation suite on relevant PRs and on every push to `main` / `renovate/**`.

[Renovate](renovate.json) watches upstream GitHub releases and opens PRs to bump the pins automatically.

This repo does not install software for you. Use the pins in [`golden.json`](golden.json) to install each component yourself, or install via [tt-installer](https://github.com/tenstorrent/tt-installer). What this repo publishes is a **validated** pin set (plus `.ttis` install schemas) that CI has exercised together.

## [`golden.json`](golden.json)

These are the system-software and compiler pieces we pin and test together as one stack. Live values are always in [`golden.json`](golden.json) (they change as Renovate merges):

| Field | Upstream |
|-------|----------|
| `kmd` | [tt-kmd](https://github.com/tenstorrent/tt-kmd) → `tenstorrent-dkms` |
| `smi` | [tt-smi](https://github.com/tenstorrent/tt-smi) |
| `flash` | [tt-flash](https://github.com/tenstorrent/tt-flash) |
| `sfpi` | [sfpi](https://github.com/tenstorrent/sfpi) (compiler toolchain) |
| `hugepages` | [tt-system-tools](https://github.com/tenstorrent/tt-system-tools) → `tenstorrent-tools` |
| `firmware` | [tt-system-firmware](https://github.com/tenstorrent/tt-system-firmware) |
| `metal-version` | [tt-metal](https://github.com/tenstorrent/tt-metal) (Metalium / default `upstream-tests-bh*` tag) |
| `installer` | [tt-installer](https://github.com/tenstorrent/tt-installer) (release CI uses to install) |

On release, the published `golden.json` also gets a `test-sha` field (not kept in the repo copy): the commit on `main` that passed validation before the release was cut.

## Renovate

Without automation, keeping pins current means watching every component’s GitHub Releases and hand-editing [`golden.json`](golden.json). Renovate does that tracking for you.

The **Renovate** workflow runs daily (and on demand). Configured by [`renovate.json`](renovate.json), it polls upstream releases, then opens or updates a grouped PR (typically `renovate/golden-versions`) with the bump(s). That PR runs the same full CI as any other change — merge only when checks are green (`automerge` is off). Day-to-day work is “review a green Renovate PR,” not “chase every component release.”

Manual run: Actions → **Renovate** → Run workflow (optional dry-run logs without opening PRs).

## CI tests

The same suite runs on every relevant PR, on Renovate bump PRs, on pushes to `main` / `renovate/**`, and again when **Golden — release** is dispatched. (Post-merge pushes may skip if the same content already passed on the PR.)

1. **Distro install + `.ttis` export** — On GitHub-hosted `ubuntu-latest`, spin up Docker images for **Ubuntu 22.04**, **Ubuntu 24.04**, **Debian 13**, and **Fedora 43**. Install the [`golden.json`](golden.json) pins with tt-installer, export a per-distro `.ttis`, validate it, and round-trip import. These `.ttis` files become release artifacts.

2. **Hardware install** — On the HW runners, install the stack with tt-installer (`--hw --force-flash`) so KMD, tools, firmware, and Metal images match the pins.

3. **Version verify** — On the HW runners, confirm installed packages/CLIs match [`golden.json`](golden.json) (`verify-versions.sh`).

4. **PCI reset stress** — On the HW runners, run `tt-smi -r` ten times (`smi-reset.sh`).

5. **SMI snapshot** — On the HW runners, run `tt-smi -s` and print board state into the job log (`smi-snapshot.sh`).

6. **Metal upstream** — On the HW runners, run the syseng-style upstream suite (`metal-upstream.sh` / `upstream-tests-bh*`, host weights under `/opt/tenstorrent/hf-models`). Full logs are uploaded as `metal-upstream-<board>-output` artifacts.

| Machines | Role |
|----------|------|
| `ubuntu-latest` (GitHub-hosted) | Distro container matrix (item 1) |
| HW runners (self-hosted & shared with system FW) | Hardware suite (items 2–6) |

## Release

Dispatch **Golden — release** from `main` when you want a published golden. The workflow re-runs the full CI suite above, then publishes a tagged GitHub Release (`vYYYY.MM.DD`). Routine push/PR CI does **not** publish a release.

### Release contents

Each release attaches:

| File | Contents |
|------|----------|
| `golden.json` | Repo pins **plus** `test-sha` (validation commit) |
| `ubuntu-22.04.ttis` | tt-installer schema from a real install on Ubuntu 22.04 |
| `ubuntu-24.04.ttis` | Same for Ubuntu 24.04 |
| `debian-13.ttis` | Same for Debian 13 |
| `fedora-43.ttis` | Same for Fedora 43 |

The `.ttis` files are **exported from CI installs**, not hand-written. Consumers use these with tt-installer (`--import-schema` / `ttis.sh`); see [tt-installer](https://github.com/tenstorrent/tt-installer).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Prefer component repos or tt-installer for product issues — this repo is not the place for them.

## License

Apache License 2.0 unless noted otherwise: [LICENSE](LICENSE), [LICENSE_understanding.txt](LICENSE_understanding.txt), [NOTICE](NOTICE).

Copyright (c) 2025-2026 Tenstorrent USA, Inc.
