#!/usr/bin/env python3
"""Write the body of a golden release: golden stack, tests run, new tests.

Inputs:
  --golden     the release golden.json (with test-sha)
  --jobs       the release run's jobs, one JSON object per line, as returned by
               GET /repos/{repo}/actions/runs/{run_id}/jobs?filter=latest
               (latest attempt of each job, so re-run jobs count once)
  --previous   optional: the previous release's body, to find tests added since
  --header     optional: markdown to put first (semver bump line, reason)

The "Tests run" table comes from the jobs' steps, so a test added to a workflow
shows up without changing this script. A step counts as a test unless it is
plumbing (setup, checkout, uploads, ...; see PLUMBING). Skipped steps (for
example metal upstream on the super cluster nodes) do not count.

The body ends with a hidden <!-- golden-tests: [...] --> list. The next release
compares its own tests with it to write the "New tests" section, which is left
out when nothing was added or when the previous release has no list.
"""
import argparse
import json
import re
import sys

STACK = [  # golden.json key, display name, upstream repo
    ("kmd", "tt-kmd", "tenstorrent/tt-kmd"),
    ("smi", "tt-smi", "tenstorrent/tt-smi"),
    ("flash", "tt-flash", "tenstorrent/tt-flash"),
    ("sfpi", "sfpi", "tenstorrent/sfpi"),
    ("hugepages", "hugepages (tenstorrent-tools)", "tenstorrent/tt-system-tools"),
    ("firmware", "firmware", "tenstorrent/tt-system-firmware"),
    ("metal-version", "tt-metal", "tenstorrent/tt-metal"),
    ("installer", "tt-installer", "tenstorrent/tt-installer"),
]

# Steps that are not tests.
PLUMBING = re.compile(
    r"^(Set up |Complete job|Post |Checkout|Remove root-owned|Return .* to the runner user|"
    r"Upload |Download |Make the Tenstorrent apt key|Install jq|Pick the tt-metal|"
    r"Assemble |Derive |Create GitHub Release|Run fkirc|Run actions/|Compare platform firmware)")

# Shorter names for known test steps. Anything else keeps its step name.
DISPLAY = [
    (re.compile(r"^Install \+ export \+ test \.ttis"), "Distro install + .ttis export and import"),
    (re.compile(r"^Install golden stack"), "Install + firmware flash (tt-installer)"),
    (re.compile(r"^Verify installed smi"), "Version verify against golden.json"),
    (re.compile(r"^Record platform firmware"), "Platform firmware record (BMC, BIOS, CPLD, chip FW)"),
    (re.compile(r"^PCI reset stress"), "PCI reset stress (10×) + NVMe check"),
    (re.compile(r"^SMI snapshot"), "SMI snapshot (tt-smi -s)"),
    (re.compile(r"^Metal upstream tests"), "Metal upstream (single host)"),
    (re.compile(r"^Preflight"), "SC4 preflight (SSH, MPI, Docker, descriptors)"),
    (re.compile(r"^Health"), "SC4 health (device holders, reset, discovery, system health)"),
    (re.compile(r"^Validation"), "SC4 validation (run_validation.sh per quad)"),
    (re.compile(r"^Fabric"), "SC4 fabric (4x32 torus stability + neighbor exchange per quad)"),
    (re.compile(r"^Recover"), "SC4 recover (clean up, reset every host)"),
]

# Jobs that hold no tests.
NOT_TESTS = re.compile(r"^(Skip duplicate check|Publish golden release|Platform firmware across hosts)$")

SC_NODE = re.compile(r"^bh-glx-\d+-a\d+u\d+$")
MARKER = re.compile(r"<!--\s*golden-tests:\s*(\[.*?\])\s*-->", re.S)


def display(step):
    for pat, name in DISPLAY:
        if pat.search(step):
            return name
    return step


def machine(job_name):
    """Where a job ran, from its name: 'Hardware validation / Golden hw (p150a)' -> p150a."""
    last = job_name.split(" / ")[-1]
    if last.startswith("SC4"):
        return "BH super cluster (SC4, 8 hosts)"
    m = re.search(r"\(([^()]+)\)\s*$", last)
    return m.group(1) if m else last


def tests_run(jobs):
    """{test: {"order": n, "ran": [machine], "failed": [machine]}}"""
    tests = {}
    for job in jobs:
        if NOT_TESTS.search(job["name"].split(" / ")[-1]):
            continue
        where = machine(job["name"])
        for step in job.get("steps", []):
            if PLUMBING.search(step["name"]) or step.get("conclusion") in (None, "skipped"):
                continue
            name = display(step["name"])
            t = tests.setdefault(name, {"order": (_rank(job["name"]), step["number"]), "ran": [], "failed": []})
            t["order"] = min(t["order"], (_rank(job["name"]), step["number"]))
            t["ran"].append(where)
            if step["conclusion"] != "success":
                t["failed"].append(where)
    return dict(sorted(tests.items(), key=lambda kv: kv[1]["order"]))


def _rank(job_name):
    if "No-hardware" in job_name or ".ttis" in job_name or "Install + export" in job_name:
        return 0
    if "SC4" in job_name:
        return 2
    return 1


def machines(names):
    """Group the super cluster nodes; keep everything else by name."""
    sc = sorted(n for n in set(names) if SC_NODE.match(n))
    rest = sorted(set(names) - set(sc))
    out = rest + ([f"BH super cluster ×{len(sc)}"] if sc else [])
    return ", ".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--golden", required=True)
    ap.add_argument("--jobs", required=True)
    ap.add_argument("--previous")
    ap.add_argument("--header", default="")
    a = ap.parse_args()

    golden = json.load(open(a.golden))
    jobs = [json.loads(l) for l in open(a.jobs) if l.strip()]
    tests = tests_run(jobs)
    out = []
    if a.header.strip():
        out += [a.header.strip(), ""]

    out += ["## Golden stack", "", "| Component | Version |", "|---|---|"]
    for key, name, repo in STACK:
        if key in golden:
            out.append(f"| [{name}](https://github.com/{repo}) | `{golden[key]}` |")
    known = {k for k, _, _ in STACK} | {"test-sha"}
    for key in sorted(set(golden) - known):  # a pin added later still shows
        out.append(f"| {key} | `{golden[key]}` |")
    if golden.get("test-sha"):
        sha = golden["test-sha"]
        out += ["", f"Validated at [`{sha[:7]}`](https://github.com/tenstorrent/tt-sw-manifest/commit/{sha}) "
                    "(`test-sha` in the attached `golden.json`)."]

    out += ["", "## Tests run", ""]
    if tests:
        out += ["| Test | Machines | Result |", "|---|---|---|"]
        for name, t in tests.items():
            n, bad = len(t["ran"]), len(t["failed"])
            result = f"✅ {n}/{n}" if not bad else f"❌ {n - bad}/{n} (failed: {machines(t['failed'])})"
            out.append(f"| {name} | {machines(t['ran'])} | {result} |")
    else:
        out.append("No test results were found for this run.")

    previous = None
    if a.previous:
        m = MARKER.search(open(a.previous).read())
        previous = json.loads(m.group(1)) if m else None
    if previous is not None:
        added = [t for t in tests if t not in previous]
        removed = [t for t in previous if t not in tests]
        if added:
            out += ["", "## New tests", "", "Added since the previous release:", ""]
            out += [f"- {t}" for t in added]
        if removed:
            out += ["", "## Tests no longer run", ""]
            out += [f"- {t}" for t in removed]

    out += ["", f"<!-- golden-tests: {json.dumps(list(tests))} -->"]
    print("\n".join(out))


if __name__ == "__main__":
    sys.exit(main())
