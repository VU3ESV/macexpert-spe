#!/usr/bin/env python3
"""
analyze_captures.py — reverse-engineer the SPE 1.5K-FA RCU 0x6A LCD packet.

Reads one or more capture log files produced by MacExpert's RCU Capture pane
(format: `ISO8601 | label | hex_bytes`, comments prefixed with `#`) and prints
three reports:

  1. Per-byte constancy: which byte positions are constant globally vs. constant
     within a label vs. varying. Likely framing/version bytes pop out as global
     constants; screen/cursor IDs pop out as label-constants.

  2. ASCII window: the most-common packet for each label, rendered as ASCII with
     non-printables shown as `.`. The LCD frame buffer is almost always visible
     here at a fixed offset.

  3. Optional --diff A B: byte-by-byte side-by-side of the most-common packet
     for two labels. Highlights every changed offset.

Usage:
    python3 analyze_captures.py ~/Documents/Tech/MacExpert-captures/capture-*.log
    python3 analyze_captures.py capture.log --diff LOGO OP_14MHz_Ant1
"""

from __future__ import annotations

import argparse
import collections
import glob
import os
import sys
from typing import Iterable


def load(paths: Iterable[str]) -> dict[str, list[list[int]]]:
    """Returns {label: [packet_bytes, ...]}."""
    by_label: dict[str, list[list[int]]] = collections.defaultdict(list)
    seen = 0
    for raw_path in paths:
        for path in glob.glob(os.path.expanduser(raw_path)):
            with open(path, "r", encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    parts = [p.strip() for p in line.split("|")]
                    if len(parts) != 3:
                        continue
                    _ts, label, hex_bytes = parts
                    try:
                        pkt = [int(b, 16) for b in hex_bytes.split()]
                    except ValueError:
                        continue
                    if not pkt:
                        continue
                    by_label[label].append(pkt)
                    seen += 1
    print(f"Loaded {seen} packets across {len(by_label)} labels.\n")
    return by_label


def packet_length(by_label: dict[str, list[list[int]]]) -> int:
    lengths = {len(p) for pkts in by_label.values() for p in pkts}
    if len(lengths) != 1:
        print(f"WARNING: mixed packet lengths {sorted(lengths)} — using max", file=sys.stderr)
    return max(lengths) if lengths else 0


def constancy_report(by_label: dict[str, list[list[int]]], length: int) -> None:
    print("=" * 78)
    print("BYTE CONSTANCY REPORT")
    print("=" * 78)
    print(f"{'pos':>3} {'kind':<14} values")
    print("-" * 78)

    all_packets = [p for pkts in by_label.values() for p in pkts]

    for i in range(length):
        global_vals = {p[i] for p in all_packets if i < len(p)}
        per_label_vals = {
            label: {p[i] for p in pkts if i < len(p)} for label, pkts in by_label.items()
        }
        if len(global_vals) == 1:
            kind = "GLOBAL_CONST"
            sample = f"0x{next(iter(global_vals)):02X}"
        elif all(len(v) == 1 for v in per_label_vals.values()):
            kind = "LABEL_CONST"
            uniq = {next(iter(v)) for v in per_label_vals.values()}
            sample = " ".join(f"0x{x:02X}" for x in sorted(uniq))
            if len(uniq) > 8:
                sample = sample.split(maxsplit=8)[0] + f" (+{len(uniq) - 8} more)"
        else:
            kind = "VARYING"
            uniq = sorted(global_vals)
            shown = " ".join(f"0x{x:02X}" for x in uniq[:8])
            if len(uniq) > 8:
                shown += f" (+{len(uniq) - 8})"
            sample = shown
        print(f"{i:>3} {kind:<14} {sample}")
    print()


def most_common_packet(packets: list[list[int]]) -> list[int]:
    counts = collections.Counter(tuple(p) for p in packets)
    return list(counts.most_common(1)[0][0])


def decode_byte(b: int) -> str:
    """
    Decode one LCD byte for display, handling SPE's attribute convention:
      * 0x20-0x3F are "highlighted/inverse" chars whose real ASCII is byte+0x20
        (e.g. 0x33 -> 'S', 0x25 -> 'E', 0x34 -> 'T')
      * 0x40-0x7E are normal printable ASCII
      * Everything else renders as '.'
    """
    if 0x20 <= b <= 0x3F:
        return chr(b + 0x20).lower()  # render highlighted as lowercase so you can tell them apart
    if 0x40 <= b <= 0x7E:
        return chr(b)
    return "."


def ascii_window(by_label: dict[str, list[list[int]]]) -> None:
    print("=" * 78)
    print("LCD RENDER (most-common packet per label, attribute-decoded)")
    print("   lowercase = highlighted/inverse attribute; UPPERCASE = normal")
    print("=" * 78)
    for label in sorted(by_label):
        pkt = most_common_packet(by_label[label])
        rendered = "".join(decode_byte(b) for b in pkt)
        print(f"\n[{label}]  ({len(pkt)} bytes)")
        # 32-col wide blocks, with byte offset gutter
        for off in range(0, len(pkt), 32):
            chunk = rendered[off : off + 32]
            print(f"  {off:>3}: {chunk}")
    print()


def diff_labels(by_label: dict[str, list[list[int]]], a: str, b: str) -> None:
    if a not in by_label or b not in by_label:
        missing = [x for x in (a, b) if x not in by_label]
        print(f"Unknown label(s): {missing}", file=sys.stderr)
        sys.exit(1)
    pa = most_common_packet(by_label[a])
    pb = most_common_packet(by_label[b])
    n = max(len(pa), len(pb))
    print("=" * 78)
    print(f"DIFF: {a}  vs  {b}")
    print("=" * 78)
    print(f"{'pos':>3}  {a:>20}  {b:>20}  ascii")
    print("-" * 78)
    for i in range(n):
        va = pa[i] if i < len(pa) else None
        vb = pb[i] if i < len(pb) else None
        if va == vb:
            continue
        sa = "--" if va is None else f"0x{va:02X}"
        sb = "--" if vb is None else f"0x{vb:02X}"
        ca = "." if va is None or not (32 <= va <= 126) else chr(va)
        cb = "." if vb is None or not (32 <= vb <= 126) else chr(vb)
        print(f"{i:>3}  {sa:>20}  {sb:>20}  {ca!r} -> {cb!r}")
    print()


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="+", help="Capture log files (globs ok).")
    ap.add_argument("--diff", nargs=2, metavar=("LABEL_A", "LABEL_B"), help="Show diff of two labels.")
    ap.add_argument("--no-constancy", action="store_true", help="Skip the constancy report.")
    ap.add_argument("--no-ascii", action="store_true", help="Skip the ASCII render.")
    args = ap.parse_args()

    by_label = load(args.paths)
    if not by_label:
        print("No packets loaded.", file=sys.stderr)
        sys.exit(1)

    length = packet_length(by_label)

    if not args.no_constancy:
        constancy_report(by_label, length)
    if not args.no_ascii:
        ascii_window(by_label)
    if args.diff:
        diff_labels(by_label, args.diff[0], args.diff[1])


if __name__ == "__main__":
    main()
