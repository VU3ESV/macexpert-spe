# How MacExpert Achieved Live LCD Mirroring of the SPE Expert 1.5K-FA

## The Problem

The SPE 1.5K-FA exposes only a 67-byte CSV status string over its USB-serial port (per the official Programmer's Guide). That CSV gives you *operating* values — power, SWR, voltage, temperature, current band/antenna — but it tells you **nothing** about the amp's LCD: which SETUP screen is up, where the cursor sits, what each sub-menu shows, what the antenna matrix is configured as. None of the menu / cursor / configuration data is in the documented protocol.

To make MacExpert behave like a real remote panel, we had to mirror the LCD itself. SPE's own KTerm tools do this via an undocumented binary mode — but its format isn't published.

## Reverse-Engineering the Hidden Protocol

### Discovery phase — capture pipeline

We built a `CaptureLogger` + `tools/analyze_captures.py` toolchain that logs every byte off the wire while we navigated the amp's panel manually. The raw byte stream contains two kinds of frames after the standard `0xAA 0xAA 0xAA` sync:

- **`0x43`** — the documented 67-byte CSV status (length is `0x43` = 67 decimal).
- **`0x6A`** — an **undocumented** "RCU display" frame, ~371 bytes, only emitted while the amp is in *RCU mode* (commands `0x80`/`0x81` toggle it).

The 0x6A type byte gives the protocol its informal name "RCU LCD frames". They are **not** length-prefixed — frames are delimited sync-to-sync (or by a quiet period), which had to be empirically determined.

### Cracking the encoding

By pressing one button at a time and diffing the captured bytes, we worked out the layout:

- **Bytes 0-31**: title bar text. Encoded with an "attribute" scheme — the high bit and bit 5 of each character carry inverse-video flags. Specifically: bytes `0x10-0x3F` are *attributed* characters whose real ASCII = `byte + 0x20` (so attributed `'S'` is `0x33`, plain `'S'` is `0x53`). Bytes `0x40-0x7E` are normal ASCII. Everything else is custom LCD glyphs (separators, icons).
- **Bytes 32-191**: body text (5 LCD rows × varying width).
- **Bytes 192-223**: footer status bar.
- **Bytes 224-319**: footer hint text (e.g. "[SET]: CONFIRM").
- **Bytes 320-364**: cursor bit-flag region — for grid menus, exactly one byte in a per-column sub-range is non-zero, and its value (`0x02`/`0x04`/`0x08`/`0x10`/`0x20`) identifies the row. Some menus use ascending bits, others descending; some span multiple rows of a column with the same bit value.

This led to two foundational helpers:

- **`Models/LCDText.swift`** — attribute-aware decoder.
- **`Models/GridCursorDecoder.swift`** — per-menu cursor decoders, since each menu has its own column boundaries and bit-mapping convention. Six different decoders were needed: SETUP root, CAT, CONFIG, TEMP/FANS, RX ANT, TUN ANT, YAESU model picker, TEN-TEC model picker, BAUD RATE, TUN ANT → PORT.

### Per-screen field extraction

Each menu encodes its data slightly differently. We built per-screen parsers in `Models/RCUFrame.swift`:

- **Antenna matrix** — text-regex parse `(\d+)\s+M:\s+(\S+)\s+(\S+)` extracts every band's two slot assignments (`"1b"`, `"2t"`, `"3r"`, `"NO"`) from one frame.
- **CONFIG** — five specific bytes encode the 5 checkboxes (BNK A/B, Remote ANT, SO2R, Combiner).
- **TEMP/FANS / RX ANT / TUN ANT** — keyword extraction (`"CELSIUS" / "FARENHEIT"`, `"YES" / "NO"` patterns).
- **MANUAL TUNE** — frequency, L (µH), C (pF), SWR, temperature pulled from positioned text fields.
- **CAT BAUD RATE** — interleave-aware extractor, because the LCD packs `"CAT : YAESU 1200 19200"` into one row with the right-column baud rates immediately after the CAT type. The extractor splits on a known baud-rate set rather than whitespace.
- **CAT/DISP info screens** — segment-based decoder that splits on runs of 3+ spaces (the amp's natural field separator).

### Cursor cracking — empirical

For some menus (TUN ANT → PORT in particular) we couldn't deduce the cursor encoding from a single capture. We navigated the cursor through specific positions and noted the captured bytes. From two captures (cursor on 1200, cursor on 19200) we worked out that one column uses bytes 345-352 ascending and the other uses 353-362 ascending — bordering at byte 353 with disambiguation by which side has the set bit.

### Hunting status flags (TUNE-in-progress, …) — labelled-diff method

For a status flag we know exists in firmware (front-panel TUNE LED, alarm state, ATU bypass) but haven't yet located in the RCU payload, `tools/find_tune_bit.py` automates the hunt. The trick is to make the **only difference between the two captures** be the flag itself — same LCD screen, same amp mode, just the bit toggling. For the TUNE LED this is easy because the SPE refuses to enter TUNE while PTT is on, so you can press TUNE in STBY *without keying the rig*: the LED lights for ~5 s before the amp warns "TUNING WITH NO POWER", and during that window the LCD is still on the standby logo — identical to the no-TUNE baseline except for the flag bit.

1. Open MacExpert → Capture. Amp in STBY, idle. Capture ~15 s under label `led_off`.
2. Press TUNE on the amp's front panel. Quickly switch label to `led_on` and capture every frame you can during the ~5 s LED window.
3. Run `python3 tools/find_tune_bit.py "$(ls -t ~/Documents/Tech/MacExpert-captures/capture-*[0-9].log | head -1)" --running led_on --idle led_off`. The script ranks every byte offset by mode-stability and discrimination strength, with a hard preference for single-bit flips (the typical shape of a flag register written by firmware).
4. The top-strength entry (≥ 0.9, single bit) gets flagged `** tune-flag candidate`. Cross-check it against the known offset map in this doc, then plumb it into `RCUFrame` as a new accessor (e.g. `isTuneInProgress`).

The same machinery generalises — relabel captures and use `--running` / `--idle` to hunt any binary state (alarm vs no-alarm, ATU bypass vs ATU active). The key invariant is *same LCD screen in both labels*; otherwise the script just rediscovers the screen-classifier bytes instead of the flag.

## Bridging Frames to UI

`RCUFrame.parse(_ data: Data)` produces a single immutable struct from one 367-byte payload. The **screen classifier** is a header-substring matcher that distinguishes the ~20 different screens (SETUP root, CAT menu, CONFIG, antenna matrix, all 14 sub-menus, info screens, OPERATE/STANDBY, etc.). It runs before the body-text classifier so longer titles win over the broad STANDBY markers.

`AmplifierViewModel.handleRCUFrame(_:)` consumes each parsed frame:

- Sets `isInSetupMode` / `activeSubMenu` / `subMenuCursorIndex` from the frame's screen + cursor.
- Updates `antennaMatrix`, `standbyBannerLines`, `infoScreenLines`, `cachedCatType` etc.
- Suppresses cursor updates for **600 ms** after the user pressed ◀/▶ in the app, so a stale RCU frame doesn't bounce the cursor back to where it was before.
- Watchdog clears the info-screen overlay if no fresh info frame arrives within 2 s (covers the case where the amp transitions back to standby and we miss the transition frame).

SwiftUI views (`Views/SetupSubMenuViews.swift`) read directly off the view model — they're pure data-driven, no imperative state.

## Tick Strategy: Always-Live Mirror

The amp only emits a 0x6A frame when its display state *changes*. To get a continuous live mirror we run a heartbeat: every 400 ms (serial) or 500 ms (Pi-side), send `RCU_OFF` → 60 ms gap → `RCU_ON`. The OFF resets the amp's "last reported state" marker so the next ON always triggers a fresh frame, even on a static screen. This gives us 2 frames/sec of forced refresh on top of any change-driven frames.

CSV polling continues alongside (1 Hz idle, 5 Hz TX). Both streams coexist on the same wire — the parser disambiguates via the type byte (`0x43` vs `0x6A`).

## Cross-Transport Parity (WebSocket)

The original `spe-remote` Pi server only forwarded CSV state as JSON. We rewrote its serial handler to:

1. Use a daemon thread doing blocking `pyserial.read()` (the asyncio wrapper had a known "readiness to read but returned no data" glitch on USB-serial that bounced the port every few seconds).
2. Demux 0x43 (CSV) and 0x6A (RCU) frames from the same byte stream via `bytearray.find()`-based sync scanning.
3. Run the same RCU OFF/ON ticker as MacExpert's serial path.
4. Forward each raw 0x6A payload to all connected clients as a **binary** WebSocket message.

On the MacExpert side, `WebSocketConnection` routes binary frames straight into `onRCUDisplayPacket` — the same callback the serial path uses. Above that level, the entire RCU pipeline (parser, view model, sub-menu views) doesn't know or care which transport it's on.

## Threading Model (don't break this)

`SerialConnection` is `@MainActor` for its public API but **never** runs an actual `port.send()`, `port.dtr =`, `port.rts =`, `port.open()`, or `port.close()` on the main thread. All of those are dispatched onto a private `ioQueue` (a serial DispatchQueue). Reason: ORSSerialPort's `send()` calls POSIX `write()` synchronously; if the FTDI's TX buffer is full or the device is unresponsive, the kernel mutex sleeps until the buffer drains — potentially seconds, or forever if the device hangs. A spindump from a real-world hang showed the main thread wedged for ~6 minutes inside `iosswrite → lck_mtx_sleep` because the cable had been unplugged mid-write.

Timer-driven writes (CSV poll + RCU OFF/ON ticker + quiet-period flush) use `DispatchSourceTimer` running directly on `ioQueue`, so neither the timer firing nor the resulting write touches the main thread. UI-affecting state and callbacks bridge back to `@MainActor` via explicit `Task { @MainActor in … }` hops.

If you ever add a new public method that touches the port, follow the same pattern: take a captured reference to `port`, dispatch the work onto `ioQueue`, return immediately. The main thread must never block on serial I/O.

## Two-Way Mirroring

Commands flow back through the same path: ◀/▶/SET on MacExpert sends the corresponding 6-byte command packet to the amp (or Pi-server-relayed command), which moves the cursor / commits the action. The next RCU tick reflects the change visually, closing the loop. The 600 ms cursor-update suppression ensures the user's intent isn't overwritten by a frame that hasn't seen the command yet.

## End Result

| Surface on the amp's LCD | Status in MacExpert |
|---|---|
| SETUP root (4×3 grid) | Cursor ✓, items ✓ |
| CAT menu (3×3 grid) | Cursor ✓, manufacturer cached for status chip |
| CONFIG | Cursor ✓, all 5 checkbox states ✓ |
| TEMP/FANS | Cursor ✓, live °C/°F + NORMAL/CONTEST |
| RX ANT, TUN ANT | Cursor ✓, YES/NO per antenna |
| ANTENNA matrix | All 11 bands × 2 slots × `b`/`t`/`r` suffixes |
| ALARMS LOG | Parsed entries with index + input + reason |
| MANUAL TUNE | Live frequency + L + C + SWR + temp |
| YAESU / TEN-TEC / BAUD RATE / TUN ANT PORT | Cursor + decoded values |
| CAT / DISP info screens | Read-only LCD mirror, two-column for CAT SETTING REPORT |
| STANDBY | Full-area banner mirroring "EXPERT 1.5K FA / SOLID STATE / FULLY AUTOMATIC / STANDBY" |
| Warnings / alarms | Full-area alert banner, replaces main display |

Every one of these works **both directions** — change made on the amp panel reflects in MacExpert within ~500 ms; change made in MacExpert is sent to the amp and confirmed in the next frame.

The whole RCU protocol — 22 commands, 367-byte frame format, attribute encoding, per-menu cursor schemes, per-screen field layouts — was reverse-engineered from scratch using nothing but a USB-serial cable, a capture log, and a lot of button-pressing. None of it is documented by SPE.
