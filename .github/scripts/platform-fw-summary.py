#!/usr/bin/env python3
"""Compare the platform firmware recorded by platform-fw.sh across hosts.

Reads every platform-fw-*.txt under a directory ("FW|<key>|<value>" lines) and
prints a Markdown table: one row per component, one column per host. Rows
where hosts disagree are flagged, so a node left on an old BMC, BIOS or CPLD
stands out. Identity rows (host, serial) are not compared.

Usage: platform-fw-summary.py <dir>   (appends to $GITHUB_STEP_SUMMARY if set)
Exit 0 always: the table is a record, not a gate.
"""
import os
import pathlib
import sys

NOT_COMPARED = {"host", "board.serial"}


def main():
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    hosts = {}
    for f in sorted(root.rglob("platform-fw-*.txt")):
        values = {}
        for line in f.read_text().splitlines():
            parts = line.split("|", 2)
            if len(parts) == 3 and parts[0] == "FW":
                values[parts[1]] = parts[2]
        if values:
            hosts[values.get("host", f.stem.removeprefix("platform-fw-"))] = values
    if not hosts:
        print("No platform-fw-*.txt files found.")
        return

    names = sorted(hosts)
    keys = []
    for h in names:
        keys += [k for k in hosts[h] if k not in keys and k != "host"]

    differ, per_host, same = [], [], []
    for k in keys:
        vals = [hosts[h].get(k, "missing") for h in names]
        known = {v for v in vals if not v.startswith("n/a")}
        if len(set(vals)) == 1:
            same.append(f"| {k} | {vals[0]} |")
            continue
        if k not in NOT_COMPARED and len(known) > 1:
            differ.append(k)
            # Bold the values that differ from the most common one.
            common = max(known, key=vals.count)
            vals = [f"**{v}**" if v != common and not v.startswith("n/a") else v for v in vals]
            k = f"⚠️ {k}"
        per_host.append(f"| {k} | " + " | ".join(vals) + " |")

    out = [
        f"### Platform firmware across {len(names)} hosts",
        "",
        f"Differs between hosts: **{', '.join(differ)}**" if differ else "All hosts match.",
        "",
        "| Component | " + " | ".join(n.replace("bh-glx-", "") for n in names) + " |",
        "|---|" + "---|" * len(names),
        *per_host,
        "",
        "Same on every host:",
        "",
        "| Component | Version |",
        "|---|---|",
        *same,
    ]

    text = "\n".join(out) + "\n"
    print(text)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write(text)
    for k in differ:
        print(f"::warning title=Platform firmware differs::{k} is not the same on every host")


if __name__ == "__main__":
    main()
