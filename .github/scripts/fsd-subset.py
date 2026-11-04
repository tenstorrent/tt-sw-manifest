#!/usr/bin/env python3
"""Cut a Factory System Descriptor (FSD) down to a set of hosts.

The provisioner's FSD describes the whole exabox (200+ hosts). The SC4 tests
run on a few of them, and run_cluster_validation reports every FSD connection
it does not discover as missing, so it needs an FSD that holds only the hosts
in the run. This keeps those hosts, their boards and the Ethernet connections
whose two ends are both kept, and renumbers host_id to match the new host list.

The FSD is a text-format protobuf with three top-level fields:
  hosts { ... }            repeated; a host's index is its host_id
  board_types { board_locations { host_id tray_id board_type } ... }
  eth_connections { connection { endpoint_a { host_id ... } endpoint_b { ... } } ... }
host_id 0 may be left out (proto3 default), so a block without one is host 0.

Usage: fsd-subset.py <fsd.textproto> <host,host,...> <out.textproto>
"""
import re
import sys

HOST_ID = re.compile(r"^(\s*)host_id:\s*(\d+)\s*$", re.M)


def top_level_blocks(text):
    """Yield (name, block_text) for each top-level `name { ... }` block."""
    i, n = 0, len(text)
    while i < n:
        m = re.compile(r"\s*([A-Za-z_]+)\s*\{").match(text, i)
        if not m:
            if text[i:].strip():
                raise ValueError(f"unexpected text at offset {i}: {text[i:i + 60]!r}")
            return
        depth, j = 1, m.end()
        while depth:
            c = text[j]
            if c == '"':  # skip quoted strings, which may hold braces
                j = text.index('"', j + 1)
                while text[j - 1] == "\\":
                    j = text.index('"', j + 1)
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
            j += 1
        yield m.group(1), text[m.start():j].strip("\n")
        i = j


def child_blocks(block, name):
    """Split the body of a block into its direct `name { ... }` children."""
    body = block[block.index("{") + 1:block.rindex("}")]
    return [b for k, b in top_level_blocks(body) if k == name]


def host_id_of(block):
    m = HOST_ID.search(block)
    return int(m.group(2)) if m else 0


def renumber(block, new_id):
    """Set host_id in a board_location or endpoint block (adds it if absent)."""
    if HOST_ID.search(block):
        return HOST_ID.sub(lambda m: f"{m.group(1)}host_id: {new_id}", block, count=1)
    head, rest = block.split("{", 1)
    indent = re.search(r"\n(\s*)\S", rest)
    return f"{head}{{\n{indent.group(1) if indent else '  '}host_id: {new_id}{rest}"


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    src, hosts_csv, out = sys.argv[1:]
    wanted = [h.strip() for h in hosts_csv.split(",") if h.strip()]
    blocks = list(top_level_blocks(open(src).read()))

    hosts = [b for k, b in blocks if k == "hosts"]
    name_of = {i: re.search(r'hostname:\s*"([^"]+)"', b).group(1) for i, b in enumerate(hosts)}
    old_id = {}
    for want in wanted:  # accept short names or FQDNs on either side
        hits = [i for i, h in name_of.items() if h == want or h.split(".")[0] == want.split(".")[0]]
        if len(hits) != 1:
            sys.exit(f"ERROR: host {want!r} matches {len(hits)} FSD hosts")
        old_id[want] = hits[0]
    new_id = {old: new for new, old in enumerate(old_id[w] for w in wanted)}

    out_blocks = [hosts[old_id[w]] for w in wanted]

    boards = [b for k, b in blocks if k == "board_types"]
    locs = [renumber(l, new_id[host_id_of(l)])
            for bt in boards for l in child_blocks(bt, "board_locations") if host_id_of(l) in new_id]
    out_blocks.append("board_types {\n" + "\n".join(_indent(l) for l in locs) + "\n}")

    conns = []
    total = 0
    for ec in (b for k, b in blocks if k == "eth_connections"):
        for c in child_blocks(ec, "connection"):
            total += 1
            a, b = child_blocks(c, "endpoint_a")[0], child_blocks(c, "endpoint_b")[0]
            ha, hb = host_id_of(a), host_id_of(b)
            if ha in new_id and hb in new_id:
                conns.append("connection {\n" + _indent(renumber(a, new_id[ha])) + "\n"
                             + _indent(renumber(b, new_id[hb])) + "\n}")
    out_blocks.append("eth_connections {\n" + "\n".join(_indent(c) for c in conns) + "\n}")

    other = sorted({k for k, _ in blocks} - {"hosts", "board_types", "eth_connections"})
    if other:
        sys.exit(f"ERROR: FSD has fields this tool does not know how to subset: {other}")

    with open(out, "w") as f:
        f.write("\n".join(out_blocks) + "\n")
    print(f"{out}: {len(wanted)} of {len(hosts)} hosts, {len(locs)} boards, "
          f"{len(conns)} of {total} connections")


def _indent(block, pad="  "):
    """Re-indent a block so its first line sits at `pad` (children keep their offsets)."""
    lines = block.splitlines()
    base = len(lines[0]) - len(lines[0].lstrip())
    return "\n".join(pad + l[base:] if l.strip() else l for l in lines)


if __name__ == "__main__":
    main()
