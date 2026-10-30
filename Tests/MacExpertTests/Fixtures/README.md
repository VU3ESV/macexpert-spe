# RCU Frame Fixtures

Real binary RCU display frames captured from a 1.5K-FA. Used as ground-
truth regression tests for `RCUFrame.parse()`. Each `.bin` file contains
the bytes **after** the `AA AA AA 6A` sync+marker — i.e. exactly what
`RCUFrame.parse(_ data: Data)` expects.

## Why fixtures matter

Every regression we hit during development (the CRLF-validation that
broke valid CSV, the heartbeat that caused flicker, the debouncer that
hid real OPER transitions) would have been caught by tests against
real frames. The protocol is reverse-engineered, so the parser is a
moving target — fixtures pin it down.

## Inventory

| File | Captured | What the amp was showing |
|---|---|---|
| `op_idle.bin` | 2026-04-16 | Operate mode, idle (power-meter scale 0/125/250/375/500) |
| `standby_idle.bin` | 2026-04-26 | STANDBY logo (EXPERT 1.5K FA / SOLID STATE / FULLY AUTOMATIC / STANDBY) |
| `setup_root.bin` | 2026-04-26 | SETUP OPTIONS 4×3 grid |
| `antenna_matrix.bin` | 2026-04-26 | SET ANTENNA ON BANK A — per-band slot table |
| `cat_settings.bin` | 2026-04-26 | CAT SETTING REPORT info screen (1st CAT press) |
| `system_info.bin` | 2026-04-26 | SYSTEM INFO info screen (2nd CAT press; firmware/serial) |
| `tun_ant_port.bin` | 2026-04-26 | TUN ANT → PORT (protocol/data bit/stop bit/parity + baud grid) |

## Adding a new fixture

1. Connect to the amp via MacExpert.
2. Toggle the developer panels on (ladybug button in the title bar).
3. Open the **RCU Capture** panel, set a label describing the screen
   (e.g. `setup_root`, `cat_yaesu_model`, `antenna_matrix_bank_a`),
   click **Start**.
4. Navigate the amp panel to the screen you want captured. Hold steady
   for ~2 seconds.
5. Click **Stop**. The capture is written to
   `~/Documents/Tech/MacExpert-captures/capture-YYYYMMDD-HHMMSS.log`.
6. Extract the first capture line's hex bytes to a `.bin` file:

   ```bash
   python3 - << 'EOF'
   import sys
   src = "/Users/manoj/Documents/Tech/MacExpert-captures/capture-YYYYMMDD-HHMMSS.log"
   out = "Tests/MacExpertTests/Fixtures/<descriptive_name>.bin"
   with open(src) as f:
       for line in f:
           if line.startswith("#") or "|" not in line:
               continue
           hex_part = line.split("|", 2)[2].strip()
           data = bytes.fromhex(hex_part.replace(" ", ""))
           open(out, "wb").write(data)
           print(f"Wrote {len(data)} bytes")
           break
   EOF
   ```

7. Add a test case in `RCUFrameTests.swift` asserting on the screen
   classification + a few key fields you expect.
8. Update the inventory table above.

## Rules

- **Do not modify fixtures.** They are captured hardware output.
  Modifying them breaks regression value.
- **Do not add synthetic fixtures.** A constructed binary is a test
  vector, not a fixture — keep them separate.
- **If a fixture produces unexpected output, investigate before changing
  the decoder.** The fixture may be revealing something the decoder
  gets wrong. That's the fixture doing its job.

(Pattern adopted from FtlC-ian/expert-amp-server's PROTOCOL.md.)
