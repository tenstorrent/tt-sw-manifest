#!/usr/bin/env python3
"""Rebuild a quad's Factory System Descriptor (FSD) from what validation discovered.

Use this when a quad is recabled and the provisioner's FSD has not caught up.
run_cluster_validation compares the FSD with the cabling it discovers and logs
both differences at channel level:

  Physical Discovery found N missing channel connections:
    - PhysicalChannelEndpoint{hostname='h', tray_id=1, asic_channel=AsicChannel{asic_location=1, channel_id=2}} <-> PhysicalChannelEndpoint{...}
  Physical Discovery found M extra channel connections:
    - ...

The new FSD is the old one minus the missing connections plus the extra ones.
Hosts and boards are kept as they are. Only the first report in the log is used;
the script fails if any later report in the same log disagrees with it, so a
link that flaps between discoveries is not baked in.

The result is the cabling as found, not as designed: review it (for example
against the cabling plan) before committing it as the SC4 baseline.

Usage: fsd-from-discovery.py <quad-fsd.textproto> <validation.log> <out.textproto>
"""
import importlib.util
import os
import re
import sys

sys.dont_write_bytecode = True  # importing fsd-subset.py must not leave __pycache__ in the repo
_spec = importlib.util.spec_from_file_location(
    "fsd_subset", os.path.join(os.path.dirname(os.path.abspath(__file__)), "fsd-subset.py"))
fsd = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fsd)

HEADER = re.compile(r"Physical Discovery found (\d+) (missing|extra) channel connections:")
ENDPOINT = re.compile(
    r"PhysicalChannelEndpoint\{hostname='([^']+)', tray_id=(\d+), "
    r"asic_channel=AsicChannel\{asic_location=(\d+), channel_id=(\d+)\}\}")


def reports(log_path):
    """Return a list of {"missing": set, "extra": set} reports, in log order."""
    out, kind = [], None
    for line in open(log_path, errors="replace"):
        m = HEADER.search(line)
        if m:
            kind, want = m.group(2), int(m.group(1))
            if kind == "missing" or not out or "extra" in out[-1]:
                out.append({})
            out[-1][kind] = set()
            out[-1]["_want_" + kind] = want
            continue
        if kind and "PhysicalChannelEndpoint" in line:
            eps = ENDPOINT.findall(line)
            if len(eps) != 2:
                sys.exit(f"ERROR: cannot parse connection line: {line.strip()}")
            out[-1][kind].add(frozenset((h.split(".")[0], int(t), int(a), int(c)) for h, t, a, c in eps))
        elif kind and "PhysicalPortEndpoint" in line:
            kind = None  # the port-level lists follow; ignore them
    for r in out:
        for kind in ("missing", "extra"):
            got, want = len(r.get(kind, ())), r.get("_want_" + kind, 0)
            if got != want:
                sys.exit(f"ERROR: log says {want} {kind} connections but {got} were parsed")
    return out


def endpoint(block):
    get = lambda k: int((re.search(rf"^\s*{k}:\s*(\d+)\s*$", block, re.M) or [0, 0])[1])
    return get("host_id"), get("tray_id"), get("asic_location"), get("chan_id")


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    src, log, out = sys.argv[1:]
    blocks = list(fsd.top_level_blocks(open(src).read()))
    other = sorted({k for k, _ in blocks} - {"hosts", "board_types", "eth_connections"})
    if other:
        sys.exit(f"ERROR: FSD has fields this tool does not handle: {other}")
    hosts = [re.search(r'hostname:\s*"([^"]+)"', b).group(1).split(".")[0] for k, b in blocks if k == "hosts"]
    host_id = {h: i for i, h in enumerate(hosts)}

    conns = set()
    for ec in (b for k, b in blocks if k == "eth_connections"):
        for c in fsd.child_blocks(ec, "connection"):
            a, b = (endpoint(fsd.child_blocks(c, e)[0]) for e in ("endpoint_a", "endpoint_b"))
            conns.add(frozenset(((hosts[a[0]],) + a[1:], (hosts[b[0]],) + b[1:])))

    reps = reports(log)
    if not reps:
        sys.exit("ERROR: no 'Physical Discovery found ... channel connections' report in the log")
    first = reps[0]
    for i, r in enumerate(reps[1:], 2):
        if r.get("missing") != first.get("missing") or r.get("extra") != first.get("extra"):
            sys.exit(f"ERROR: discovery report {i} differs from report 1; the cabling is not stable")
    missing, extra = first.get("missing", set()), first.get("extra", set())
    if not missing <= conns:
        sys.exit("ERROR: the log lists missing connections that are not in this FSD (wrong FSD?)")
    unknown = {e[0] for c in extra for e in c} - set(host_id)
    if unknown:
        sys.exit(f"ERROR: extra connections name hosts that are not in this FSD: {sorted(unknown)}")

    new = (conns - missing) | extra

    def ep_block(name, e):
        h, t, a, c = e
        lines = [f"host_id: {host_id[h]}", f"tray_id: {t}", f"asic_location: {a}"]
        if c:
            lines.append(f"chan_id: {c}")
        return f"{name} {{\n" + "\n".join("  " + l for l in lines) + "\n}"

    conn_blocks = []
    for c in sorted(new, key=lambda c: sorted((host_id[e[0]],) + e[1:] for e in c)):
        a, b = sorted(c, key=lambda e: (host_id[e[0]],) + e[1:])
        conn_blocks.append("connection {\n" + fsd._indent(ep_block("endpoint_a", a)) + "\n"
                           + fsd._indent(ep_block("endpoint_b", b)) + "\n}")
    kept = [b for k, b in blocks if k != "eth_connections"]
    kept.append("eth_connections {\n" + "\n".join(fsd._indent(c) for c in conn_blocks) + "\n}")
    with open(out, "w") as f:
        f.write("\n".join(kept) + "\n")
    print(f"{out}: {len(conns)} connections - {len(missing)} missing + {len(extra)} extra "
          f"= {len(new)} (from {len(reps)} matching discovery reports)")


if __name__ == "__main__":
    main()
