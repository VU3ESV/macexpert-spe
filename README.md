# MacExpert

Modern macOS control application for **SPE Expert HF amplifiers** (1.3K-FA / 1.5K-FA / 2K-FA).

Built with Swift and SwiftUI. Supports both **local USB serial** and **WebSocket** connections (via [spe-remote](https://github.com/vu2cpl/spe-remote)).

Full two-way mirror of the amp's LCD: cursor tracking, every sub-menu, per-band antenna matrix, CONFIG checkboxes, TEMP/FANS, RX/TUN ANT live values, ALARMS LOG, MANUAL TUNE, YAESU/TEN-TEC/BAUD RATE pickers, and TUN ANT → PORT — both transports.

## Features

### Connection
- **Dual transport** — USB serial (direct) or WebSocket (remote via `spe-remote` on Raspberry Pi). RCU LCD frames are proxied over WebSocket so live sub-menu mirroring works on both paths.
- **Auto-detect** model from serial status (1.3K / 1.5K / 2K).
- **Auto-reconnect** with exponential backoff.

### Live mirror (both directions, via RCU 0x6A LCD frames)
| Screen | Mirroring |
|---|---|
| SETUP root | 4×3 grid cursor |
| CAT menu | 3×3 cursor + active CAT type cache |
| CONFIG | Cursor + all 5 checkboxes (BNK A/B, Remote ANT, SO2R, Combiner) |
| TEMP/FANS | Cursor + live CELSIUS/FAHRENHEIT + NORMAL/CONTEST |
| RX ANT | Cursor + YES/NO per antenna (ANT2/3/4) |
| TUN ANT | Cursor + YES/NO per antenna (ANT1-4 + PORT + SAVE), lands on active ant on entry |
| TUN ANT → PORT | Protocol / data bit / stop bit / parity display + 4×2 baud cursor |
| ALARMS LOG | Parsed entries ("10 IN1: SWR EXCEEDING LIMITS") |
| MANUAL TUNE | Live CAT frequency, L µH, C pF, SWR ANT, temperature |
| DISPLAY | Local 0-16 brightness / contrast |
| ANTENNA matrix | Per-band slot 1 + slot 2 with `b` / `t` / `r` suffixes; slot 1/2 cursor tracking; SAVE row |
| YAESU / TEN-TEC / BAUD RATE | Model + speed pickers with accurate cursor decoding |
| CAT / DISP info | CAT SETTING REPORT (two-column INPUT 1 / INPUT 2 split), SYSTEM INFO, SN, HW, CAL |
| STANDBY | Banner mirroring "EXPERT / SOLID STATE / FULLY AUTOMATIC / STANDBY" with gauges (DRAIN / TEMP / VOLTAGE / SWR) still live below it |
| STANDBY + TX (bypass) | Power meter swaps in (drive only — amp is bypassed). Bar auto-ranges across `5 / 25 / 50 / 100 / 200 W` so QRP signals are still readable; chip reads e.g. `STBY 25W`. Gauges unchanged. |

### Status / meters
- **Power display** auto-scales to the LOW / MID / HIGH setting (500 / 1000 / 1500 W on 1.5K-FA). When the amp is in STANDBY but the rig is keyed (bypass), the bar auto-ranges across 5 / 25 / 50 / 100 / 200 W — picking the smallest rung that clears the current drive — so QRP through 200 W signals are all readable.
- **Arc gauges** for SWR, drain current, PA temperature, supply voltage. The TEMP gauge auto-scales to °C (0-80) or °F (32-180) following the amp's TEMP/FANS setting; tap the gauge to toggle the unit manually if you haven't visited the sub-menu yet.
- **Seven status chips** (one row): STATUS / BAND / ANT (with `b`/`t`/`r` suffix) / IN / LEVEL / MODE / CAT. Tappable ones cycle the corresponding amp setting.
- **Alert banner** — when the amp reports a warning or alarm, a full-height banner replaces the main display (same footprint as a sub-menu, so nothing shifts).
- **Amp-powered-off banner** — when the FTDI link stays up but the amp's CPU is off, the main area shows a dim "POWERED OFF" panel and the BAND / ANT / IN / LEVEL / MODE / STATUS chips clear to `—` so nothing reads stale. Detection has two sources: (a) over WebSocket, the gateway's explicit 5 s presence heartbeat (`serial: "up"|"down"`) flips the banner within ~5 s; (b) over serial, a 8 s silence watchdog driven by any received CSV state or RCU frame. CAT chip keeps its cached value across power cycles. OPER / TX / ALARM LEDs blank out too.

### ATU band sweep (WebSocket mode, requires a tune radio)
- **Sweep panel** behind the **SWEEP** button in the controls row (next to TUNE / DISP / CAT / SET). Modal sheet with a band picker (160 / 80 / 60 / 40 / 30 / 20 / 17 / 15 / 12 / 10 / 6 m), live progress bar, and Stop button.
- Drives the Pi-side orchestrator (spe-remote `tune_band:<band>`) which in turn drives the configured rig — a **FlexRadio** (SmartSDR) or a **SunSDR / ExpertSDR3** (TCI): sets the freq, sends the SPE TUNE keycode, waits for the front-panel TUNE LED (`RCUFrame.isTuneActive`, byte 4 bit 6), keys the carrier, watches the LED for ATU completion, cuts the carrier, steps to the next sub-band.
- **Radio picker.** A **RADIO** button (next to SWEEP) opens a settings sheet to choose which rig drives the tune — None / FlexRadio / SunSDR (TCI) — and edit its host/port/etc. The choice applies live on the Pi (`get_config` / `set_radio_config`) and persists to its `config.yaml`; no restart. Refused while a tune is running. Contract: spe-remote `docs/CLIENT_RADIO_CONFIG.md`.
- Sweeps the SPE manual's recommended in-amateur-band sub-band centers (`spe-remote/spe/spe_band_table.py`). 20m is 7 cycles, 80m is 25 cycles, etc.
- Stop button works mid-cycle — the carrier-off lives in a `finally` block on the Pi side, so an abort always drops TX before exiting.
- Operator's pre-sweep VFO freq + mode are snapshotted and restored at the end (VFO_SAVED → ... → VFO_RESTORED phase events).
- **On-demand radio connection.** spe-remote no longer holds the rig session open for its whole lifetime — it connects when a Sweep panel opens and disconnects when the cycle is over. MacExpert sends `radio_connect` as the Sweep sheet appears (pre-warming the rig so the first tune is instant) and `radio_disconnect` when it closes while idle. Connection transitions arrive as `RADIO_CONNECTING` / `RADIO_CONNECTED` / `RADIO_DISCONNECTED` / `RADIO_ERROR` `tune_event` phases; a `RADIO_ERROR` (e.g. radio powered off) surfaces in the app's error banner. No action is required if you skip this — the Pi also connects lazily at tune start. (Older `FLEX_*` phases are still tolerated.)
- The plain **TUNE** button is unchanged — sends the SPE TUNE keycode directly with no rig coordination, same as before. SWEEP is the orchestrated alternative.

### UI niceties
- **Fixed-height LCDContainer** — every sub-menu, standby banner, info screen, and alert banner is sized to match the power+gauges block, so the controls row below never moves as you navigate.
- **Developer panels** — RCU Capture + RCU Parser Debug are hidden by default; toggle them on via the ladybug button in the title bar for diagnosing parser / pipeline issues.
- **Apple Silicon + Intel** — universal binary (arm64 + x86_64) via `build-app.sh`.
- **Persisted settings** — connection mode, host/port, dev-panels toggle all saved across launches.
- **Reconnect on launch** — opt-out checkbox in the Connection panel. When on (default), the app restores the last `connectionMode` and auto-connects to the last server (serial port or WebSocket host) at startup. Designed for the daily-driver case where the Pi server is always running.

## Requirements

- macOS 14.0 (Sonoma) or later.
- For serial mode: USB cable to SPE Expert amplifier, and install ORSSerialPort (handled by SwiftPM).
- For WebSocket mode: [spe-remote](https://github.com/vu2cpl/spe-remote) running on a network-accessible host. The Pi needs the RCU-proxy build (commit `919e58d` or later); the presence-heartbeat fast-path needs commit `ab6d94d` or later. Older builds still work — the Mac falls back to the 8 s silence watchdog for amp-off detection.

## Install and Run

### Download a pre-built signed release

Universal (arm64 + x86_64), Developer ID Application signed:

[**Latest release →**](https://github.com/vu2cpl/macexpert-spe/releases/latest)

Download `MacExpert-vX.Y.Z-universal.zip`, unzip, drag `MacExpert.app` to `/Applications`, double-click. The build is **Apple-notarized and stapled** so Gatekeeper accepts it on first launch with no warning.

### Build via `build-app.sh` (universal binary, signed if you have the cert)

```bash
git clone https://github.com/vu2cpl/macexpert-spe.git
cd macexpert-spe
./build-app.sh
open ../MacExpert.app
```

The script builds both arm64 and x86_64 targets and fuses them with `lipo`, assembles `MacExpert.app` one level up, copies resource bundles, and codesigns with the first available `Developer ID Application` identity in your keychain. If none is present it falls back to ad-hoc signing (works locally only). Verify with:

```bash
lipo -archs ../MacExpert.app/Contents/MacOS/MacExpert
# x86_64 arm64
```

### Install the dev build into `/Applications` (`install.sh`)

After `build-app.sh` produces `../MacExpert.app`, the running copy of MacExpert is still whatever's installed in `/Applications/MacExpert.app` — Dock, Spotlight and `open -a MacExpert` all launch the install, not the build. `install.sh` does the swap:

```bash
./install.sh             # copy the existing build over /Applications/, relaunch
./install.sh --build     # run build-app.sh first, then install
./install.sh --backup    # keep the prior install as /Applications/MacExpert-prev.app
```

It quits any running MacExpert first, `rsync --delete`s the bundle into `/Applications/`, re-verifies the codesigning, and `open`s the result. Run after every `build-app.sh` when iterating on fixes — otherwise the new code never actually executes.

### Cut a release (`release.sh`)

```bash
./release.sh                                  # build + sign + zip → dist/
./release.sh --notarize                       # also Apple-notarize + staple
./release.sh --tag v2.1.0                     # also tag the current commit
./release.sh --tag v2.1.0 --push              # tag, push, GitHub release + upload
./release.sh --tag v2.1.0 --push --notarize   # full release flow
```

`--push` requires the [GitHub CLI](https://cli.github.com/). `--notarize` requires a one-time keychain credential profile named `MacExpert-Notary`:

```bash
xcrun notarytool store-credentials "MacExpert-Notary" \
    --apple-id YOUR_APPLE_ID \
    --team-id CHVNJ85C9F \
    --password YOUR_APP_SPECIFIC_PASSWORD
```

App-specific password from [account.apple.com/account/manage](https://account.apple.com/account/manage) → App-Specific Passwords.

### Open in Xcode

```bash
open Package.swift
```

Xcode resolves the SwiftPM deps and you can build/run.

### Tests

```bash
swift test
```

Runs the regression suite against real captured RCU frames stored as
binary fixtures in `Tests/MacExpertTests/Fixtures/`. See that
directory's [README](Tests/MacExpertTests/Fixtures/README.md) for the
procedure to add new fixtures from a fresh capture.

## Usage

### Serial Mode

1. Plug the SPE Expert amplifier into USB.
2. Launch MacExpert.
3. Pick **Serial** in the Connection dropdown.
4. Choose the port; baud rate stays at **115200**.
5. Click **Connect**.

### WebSocket Mode

1. Make sure `spe-remote` is running on the Pi and reachable.
2. Launch MacExpert, pick **WebSocket**.
3. Enter the Pi's IP and port (default `8888` — no comma).
4. Click **Connect**. Status chips start updating within a second; RCU-driven sub-menus populate when you enter SETUP.

### SETUP navigation

- Click **SET** on the panel to enter SETUP (only allowed in STANDBY per amp firmware).
- ◀ / ▶ navigate the cursor; SET confirms; SET on EXIT leaves the sub-menu.
- Tap the tappable status chips (BAND / ANT / IN / LEVEL / MODE) to cycle those settings directly without going through SETUP.

## SPE Protocol

Based on the **SPE Application Programmer's Guide Rev 1.1** (15.10.2015) for the documented CSV channel, plus **reverse-engineered RCU LCD protocol** for live menu mirroring — see [`docs/REVERSE_ENGINEERING.md`](docs/REVERSE_ENGINEERING.md) for the full write-up of how the 0x6A frame format, attribute encoding, per-menu cursor schemes, and tick strategy were figured out.

- Serial: 115200 baud, 8N1, no parity.
- Host-to-amp packet: `0x55 0x55 0x55 [CNT] [DATA] [CHK]`.
- Amp-to-host packet: `0xAA 0xAA 0xAA [CNT / type] [DATA] [CHK CRLF]` (CSV) or `0xAA 0xAA 0xAA 0x6A [variable payload]` (RCU LCD frame, sync-to-sync delimited).
- **CSV status** (type `0x43`): 67-byte ASCII with 19 fields, polled at 0.2 s (TX) / 1 s (idle).
- **RCU LCD frame** (type `0x6A`): ~371-byte binary payload with attribute-encoded LCD text (XOR `0x20` for bytes `0x10-0x3F`). Streamed while RCU is enabled.
- 22 commands covered: `0x01-0x11` (function keys), `0x80 / 0x81` (RCU on/off), `0x82 / 0x83` (backlight), `0x90` (status request).

## Dependencies

- [ORSSerialPort](https://github.com/armadsen/ORSSerialPort) — macOS serial port library (via SPM).

## Project Structure

```
MacExpert/
├── MacExpertApp.swift              # App entry point
├── build-app.sh                    # Universal-binary build + .app assembly
├── install.sh                      # Install dev build into /Applications + relaunch
├── release.sh                      # Build, sign, notarize, zip, GitHub-release
├── Models/
│   ├── AmplifierState.swift        # CSV-derived state (Codable; JSON over WS)
│   ├── AmplifierModel.swift        # Model enum + LOW/MID/HIGH power limits
│   ├── AntennaMap.swift            # Persisted per-band antenna cache (CSV-learned)
│   ├── SPEProtocol.swift           # Commands, packet builder, CSV parser
│   ├── RCUDisplayPacket.swift      # 0x6A frame locator (sync-to-sync)
│   ├── RCUFrame.swift              # Full parser — screen detection, cursor,
│   │                               # sub-menu fields, antenna matrix, info
│   │                               # screens, config checkboxes, isTuneActive
│   ├── LCDText.swift               # Attribute-aware LCD text decoder
│   ├── GridCursorDecoder.swift     # Per-menu cursor decoders
│   └── TuneEvent.swift             # Decodes tune_event JSON from the Pi-side
│                                   # orchestrator (Phase 2c sweep panel)
├── Connection/
│   ├── ConnectionProvider.swift    # Transport-agnostic protocol
│   ├── SerialConnection.swift      # USB serial + RCU OFF/ON ticker
│   └── WebSocketConnection.swift   # WS client; binary frames → RCU
├── ViewModels/
│   └── AmplifierViewModel.swift    # Observable state, frame handling,
│                                   # sub-menu routing, info-screen watchdog
├── Views/
│   ├── ContentView.swift           # Root layout + view routing
│   ├── ConnectionView.swift        # Serial/WS connection settings
│   ├── CaptureView.swift           # Dev-panel: RCU frame capture
│   ├── RCUDebugView.swift          # Dev-panel: parser state + frame fields
│   ├── PowerDisplayView.swift      # Power bar + readout + auto-scale ticks
│   ├── GaugeView.swift             # Arc gauges
│   ├── StatusChipsView.swift       # 7-chip row (STATUS/BAND/ANT/IN/LEVEL/MODE/CAT)
│   ├── ControlsView.swift          # TUNE / DISP / CAT / SET / SWEEP + L± / C± / ◀▶
│   ├── SweepPanelView.swift        # Phase 2c modal sheet — band picker, progress,
│   │                               # Stop. Reads tune_event broadcasts from the Pi
│   ├── LEDStatusView.swift         # SERIAL / POWER / OPER / TUNE / TX / ALARM / SET
│   ├── SetupMenuView.swift         # SETUP 4×3 grid (root)
│   └── SetupSubMenuViews.swift     # All sub-menu views + LCDContainer +
│                                   # InfoScreenView + StandbyBannerView +
│                                   # AlertBannerView + shared LCD styling
├── Capture/
│   └── CaptureLogger.swift         # Reverse-engineering capture pipeline
└── Resources/
    └── ExpertIcon.icns             # App icon
```

## Known limitations / TODO

- **Resolved 2026-06-19** — physical TUNE-button detection now works. The TUNE LED in MacExpert tracks the amp's front-panel LED via `RCUFrame.isTuneActive` (byte 4 bit 6 of the RCU LCD frame; located via the labelled-diff capture tool at `tools/find_tune_bit.py`). Latency is one RCU tick (~0.5 s).
- **CAT / DISP info screen structured parsing** — basic raw-text mirroring works; could extract structured fields per screen for richer UI.

## Credits

- Original MacExpert by Georg Isenbuerger DJ6GI/NZ1C.
- SPE protocol reference by SPE s.r.l.
- RCU proprietary-protocol reverse engineering & sub-menu decoding: **VU2CPL** (2026-04, from scratch on a 1.5K-FA) — see the in-repo capture pipeline and `tools/analyze_captures.py`.
- [spe-remote](https://github.com/vu2cpl/spe-remote) by VU2CPL.
- [ORSSerialPort](https://github.com/armadsen/ORSSerialPort) by Andrew Madsen AC7CF.

## License

Released under the MIT License — see [`LICENSE`](LICENSE). Copyright © 2026 Manoj Ramawarrier (VU2CPL).
