#!/usr/bin/env python3
"""
find_tune_bit.py — locate the SPE 1.5K-FA's TUNE-in-progress flag in the
RCU 0x6A LCD frame payload by diffing labelled captures.

Why this exists
---------------
SM5TOG's 1K-FA controller reads a tune-status bit from a 35-byte binary
RCU response (pkt[5] & 0x01). The 1.5K-FA's RCU response is the 367-byte
LCD frame instead, so MacExpert today falls back to a blind 5 s timer
(see AmplifierViewModel.swift:1186). But the amp's own front-panel TUNE
LED has to read from *some* firmware flag, and that flag almost
certainly lives in the LCD payload too — we just haven't identified it.

Capture recipe (simple — no PTT, no rig, ~30 seconds at the amp)
----------------------------------------------------------------
The SPE refuses to enter TUNE mode while PTT is on, so a TUNE press
in STANDBY with no carrier lights the front-panel TUNE LED for ~5 s
("amp waiting for carrier") before the amp gives up and warns
"TUNING WITH NO POWER". That ~5 s window has the LCD still on the
standby logo (no screen change) and the TUNE-pending firmware flag
set — exactly the comparison we want.

1. Open MacExpert → Capture pane. Amp in **STBY**, idle.
2. Label ``led_off``, capture ~15 s of the standby logo screen
   (~10 frames at the 1.5 s RCU tick).
3. **Press TUNE on the amp's front panel.** Front-panel TUNE LED
   comes on. LCD stays on the standby logo (no carrier yet).
4. Label ``led_on``, capture every frame you can during the 5 s
   window before the amp warns "TUNING WITH NO POWER" — usually
   3–5 frames is plenty.
5. Stop capture. Press TUNE again or wait for the warning so the
   amp drops back to plain STBY.

Then run:

    python3 find_tune_bit.py "$(ls -t ~/Documents/Tech/MacExpert-captures/capture-*[0-9].log | head -1)" \
        --running led_on --idle led_off

The script prints the byte offsets that *most reliably* distinguish
``tune_running`` from the other labels, sorted by discriminator
strength. Strong candidates (≥ 0.9 strength, single-bit flip) are
flagged; check the top entries against the LCD frame layout in
docs/REVERSE_ENGINEERING.md to confirm.

Output format
-------------
For each candidate byte offset we print:

    offset   running           idle              strength  diff  notes
    155      0x42 (mode 1.00) 0x40 (mode 0.95)  0.95      bit1  ** tune-flag candidate

- ``mode N.NN`` = fraction of packets in that label where the mode
  value occurs. ``1.00`` means perfectly consistent across the capture.
- ``strength`` = min of the two mode-frequencies. Closer to 1.0 means
  the byte is a clean discriminator on both sides.
- ``diff`` = bit position(s) that flipped (single-bit flips are
  preferred — they look like real flag bits).
- ``notes`` flags ``** tune-flag candidate`` when strength ≥ 0.9 AND
  exactly one bit differs.

Optional flags
--------------
    --running LABEL    name of the "TUNE LED on" label
                       (default: led_on)
    --idle LABEL       name of the comparison "TUNE LED off" label.
                       Can be repeated to demand the candidate
                       discriminate from MULTIPLE idle labels.
                       Default: led_off.
    --top N            show top N candidates (default 20)
    --bit-only         restrict to single-bit-flip candidates
                       (highest-confidence flag bits)
    --range A:B        restrict scan to offset range A..B
                       (e.g. 0:32 for the header region;
                        omit to scan the whole payload)

Returns 0 if at least one strong candidate (strength ≥ 0.9, single-bit
flip) is found, else 1 — useful for piping into a CI check once we
trust the bit.
"""

from __future__ import annotations

import argparse
import collections
import glob
import os
import sys
from typing import Iterable


def load(paths: Iterable[str]) -> dict[str, list[list[int]]]:
    """Returns {label: [packet_bytes, ...]} from MacExpert capture logs.

    Tolerates the comment lines and header that CaptureLogger writes.
    """
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
    print(f"Loaded {seen} packets across {len(by_label)} labels: "
          f"{ {k: len(v) for k, v in by_label.items()} }\n")
    return by_label


def mode_and_freq(values: list[int]) -> tuple[int, float]:
    """Most-common byte value and its fraction. Empty → (-1, 0.0)."""
    if not values:
        return -1, 0.0
    counts = collections.Counter(values)
    val, count = counts.most_common(1)[0]
    return val, count / len(values)


def bit_diff(a: int, b: int) -> list[int]:
    """List of bit positions where a and b differ (0=LSB ... 7=MSB)."""
    return [i for i in range(8) if (a ^ b) & (1 << i)]


def render_byte(b: int) -> str:
    if b < 0:
        return "----"
    ch = chr(b) if 32 <= b < 127 else "."
    return f"0x{b:02X}({ch})"


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Find the TUNE-in-progress flag bit by diffing labelled RCU captures.",
    )
    ap.add_argument("logs", nargs="+",
                    help="Capture log file(s); globs OK.")
    ap.add_argument("--running", default="led_on",
                    help="Label for 'TUNE LED on' captures.")
    ap.add_argument("--idle", action="append", default=None,
                    help="Label for 'TUNE LED off' captures. Repeat for "
                         "multi-label (default: led_off).")
    ap.add_argument("--top", type=int, default=20,
                    help="Number of top candidates to print.")
    ap.add_argument("--bit-only", action="store_true",
                    help="Restrict to single-bit-flip candidates.")
    ap.add_argument("--range", dest="byte_range", default=None,
                    help="Restrict scan to byte offsets A:B (e.g. 0:32).")
    args = ap.parse_args()

    idle_labels = args.idle or ["led_off"]
    by_label = load(args.logs)

    if args.running not in by_label:
        print(f"error: no packets found for running label {args.running!r}. "
              f"Available labels: {sorted(by_label)}", file=sys.stderr)
        return 2

    idle_found = [lab for lab in idle_labels if lab in by_label]
    if not idle_found:
        print(f"error: none of the idle labels {idle_labels} present in captures. "
              f"Available: {sorted(by_label)}", file=sys.stderr)
        return 2
    if len(idle_found) < len(idle_labels):
        missing = set(idle_labels) - set(idle_found)
        print(f"warning: idle label(s) not found in captures: {sorted(missing)}. "
              f"Continuing with {idle_found}.\n", file=sys.stderr)

    running_pkts = by_label[args.running]
    # Frame length: take the minimum across all relevant packets so we
    # never index past the end. RCU LCD payloads are nominally 367 bytes,
    # but flush-timer captures occasionally truncate by a byte or two.
    all_pkts = list(running_pkts)
    for lab in idle_found:
        all_pkts.extend(by_label[lab])
    frame_len = min(len(p) for p in all_pkts)

    if args.byte_range:
        a_s, b_s = args.byte_range.split(":")
        scan_a, scan_b = int(a_s), int(b_s)
    else:
        scan_a, scan_b = 0, frame_len
    scan_b = min(scan_b, frame_len)

    candidates: list[dict] = []
    for offset in range(scan_a, scan_b):
        run_vals = [p[offset] for p in running_pkts]
        run_mode, run_freq = mode_and_freq(run_vals)

        # The candidate must differ from EVERY listed idle label, otherwise
        # the bit isn't actually capturing "tune vs not tune" — it might
        # just be capturing one specific screen state.
        idle_modes: dict[str, tuple[int, float]] = {}
        ok = True
        weakest = 1.0
        bits_changed: set[int] = set()
        for lab in idle_found:
            vals = [p[offset] for p in by_label[lab]]
            mode_v, mode_f = mode_and_freq(vals)
            idle_modes[lab] = (mode_v, mode_f)
            if mode_v == run_mode:
                ok = False
                break
            weakest = min(weakest, mode_f)
            bits_changed.update(bit_diff(run_mode, mode_v))
        if not ok:
            continue
        weakest = min(weakest, run_freq)

        if args.bit_only and len(bits_changed) != 1:
            continue

        candidates.append({
            "offset": offset,
            "run_mode": run_mode,
            "run_freq": run_freq,
            "idle": idle_modes,
            "strength": weakest,
            "bits": sorted(bits_changed),
        })

    candidates.sort(key=lambda c: (-c["strength"], len(c["bits"]), c["offset"]))

    if not candidates:
        print("No discriminating byte found. Either captures are too small / mislabelled, "
              "or the tune flag is somewhere we're not looking (try --range 0:32 to focus "
              "on the header region, or check the capture file).")
        return 1

    # Header
    idle_header = " ".join(f"{lab:<14}" for lab in idle_found)
    print(f"{'offset':>6}  {'running':<14}  {idle_header}  {'strength':>8}  {'bits':<10}  notes")
    print("-" * (6 + 2 + 14 + 2 + (16 * len(idle_found)) + 2 + 8 + 2 + 10 + 2 + 30))

    strong_found = False
    for c in candidates[: args.top]:
        single_bit = len(c["bits"]) == 1
        strong = c["strength"] >= 0.9 and single_bit
        if strong:
            strong_found = True
        idle_str = " ".join(
            f"{render_byte(v):<10}({f:.2f})" for v, f in c["idle"].values()
        )
        # Compact "(N.NN)" attached to the idle byte; pad each cell.
        idle_cells = []
        for lab in idle_found:
            v, f = c["idle"][lab]
            idle_cells.append(f"{render_byte(v)}({f:.2f})".ljust(16))
        idle_str = " ".join(idle_cells)
        bits_str = ",".join(str(b) for b in c["bits"]) if c["bits"] else "-"
        notes = "** tune-flag candidate" if strong else ""
        print(
            f"{c['offset']:>6}  "
            f"{render_byte(c['run_mode'])}({c['run_freq']:.2f})".ljust(6 + 2 + 14 + 2)
            + f"{idle_str}  {c['strength']:.2f}      {bits_str:<10}  {notes}"
        )

    if strong_found:
        print("\nAt least one strong single-bit candidate found. Cross-check against\n"
              "docs/REVERSE_ENGINEERING.md for the byte's known purpose, then plumb\n"
              "it into RCUFrame's isTuneInProgress accessor.")
        return 0
    else:
        print("\nNo single-bit ≥0.9-strength candidate. The flag may be encoded\n"
              "differently (multi-bit code, screen-class switch). Try --top 50 and\n"
              "scan manually, or capture a longer 'tune_running' sample to stabilise\n"
              "the byte-mode estimate.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
