#!/usr/bin/env python3
"""Pick the machines a golden-hw run tests, from .github/hw-runners.json.

RUNNERS (the workflow's runners input) is a comma- or space-separated list:
  empty            every machine (the normal run)
  p300a,quietbox2  just those single-host machines
  super-cluster    the 8 BH super cluster nodes, then the SC4 cluster tests

Single super cluster nodes cannot be picked on their own: the per-node job
resets that Galaxy, which would break SC4 tests running on the cluster, and SC4
needs all eight nodes.

Writes single_host=<json> and super_cluster=<json> (matrix include lists) to
$GITHUB_OUTPUT, or prints them when it is not set. Exits 1 on an unknown name.
"""
import json
import os
import re
import sys

SC_TOKEN = "super-cluster"


def plan(runners_json, requested):
    machines = json.load(open(runners_json))
    keep = lambda m: {k: m[k] for k in ("runner", "labels", "label")}
    single = [keep(m) for m in machines["single_host"]]
    sc = [keep(m) for m in machines["super_cluster"]]
    names = [n for n in re.split(r"[\s,]+", requested.strip()) if n]
    if not names:
        return single, sc

    single_names = {m["runner"] for m in single}
    sc_names = {m["runner"] for m in sc}
    errors = []
    for n in names:
        if n in sc_names:
            errors.append(f"{n} is a super cluster node; nodes cannot run alone "
                          f"(use '{SC_TOKEN}' for all eight nodes plus SC4)")
        elif n not in single_names and n != SC_TOKEN:
            errors.append(f"unknown machine {n!r}")
    if errors:
        valid = ", ".join(sorted(single_names) + [SC_TOKEN])
        sys.exit("ERROR: " + "; ".join(errors) + f". Valid names: {valid}")
    return [m for m in single if m["runner"] in names], (sc if SC_TOKEN in names else [])


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    runners_json = os.path.join(here, "..", "hw-runners.json")
    single, sc = plan(runners_json, os.environ.get("RUNNERS", ""))
    lines = [f"single_host={json.dumps(single)}", f"super_cluster={json.dumps(sc)}"]
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as f:
            f.write("\n".join(lines) + "\n")
    print("\n".join(lines))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write("### Machines in this run\n\n"
                    f"- Single host: {', '.join(m['runner'] for m in single) or 'none'}\n"
                    f"- Super cluster + SC4: {'yes' if sc else 'no'}\n")


if __name__ == "__main__":
    main()
