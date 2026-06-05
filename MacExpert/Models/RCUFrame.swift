import Foundation

/// One parsed SPE 1.5K-FA LCD display frame.
///
/// Produced by `RCUFrame.parse(_:)` from the 367-byte payload of an
/// `AA AA AA 6A ...` packet. Carries the decoded fields MacExpert's UI needs
/// to mirror the amp's physical display in real time. See
/// `memory/reference_spe_rcu_protocol.md` for the byte-offset source of truth.
struct RCUFrame: Equatable {
    /// Which LCD screen the amp is currently showing, detected via the
    /// decoded header text in bytes 0-31.
    let screen: DetectedScreen

    /// Decoded header (bytes 0-31). Useful for debugging / logging.
    let header: String

    /// Decoded footer (bytes 224-320). The context-help line.
    let footer: String

    /// Selected memory bank as it appears on screen (byte 33).
    /// Attributed 'a' (0x21) or 'b' (0x22).
    let bankLetter: Character?

    /// Grid menu cursor position, if this screen uses the grid cursor scheme.
    /// `row` matches the column-first nav order the UI already uses.
    let gridCursorNavIndex: Int?

    /// Backlight bar level, 0-2, derived from the position of `0x96` in
    /// bytes 101-103 (3-cell bar on the DISPLAY screen). Nil if not on
    /// DISPLAY or the bar isn't in a decodable state.
    let backlightLevel: Int?

    /// Contrast bar level. Same position-based encoding as backlight but in
    /// the contrast-row byte range (~177-197 on the LCD). Nil if not on
    /// DISPLAY or the filled cell isn't found.
    let contrastLevel: Int?

    /// CONFIG sub-menu checkbox + bank selection state. Nil unless we're
    /// on the CONFIG ("OTHER SETTINGS") screen.
    let configState: ConfigState?

    /// True when the amp is overlaying its "ANTENNA NOT AVAILABLE" banner
    /// (no antenna assigned to the currently-selected band).
    let antennaNotAvailable: Bool

    /// Status-bar current band readout (footer area, bytes 289-291).
    /// Nil on screens where the status bar isn't rendered.
    let currentBandLabel: String?

    /// Current antenna digit from the status bar (byte 295). Nil if the
    /// byte decodes to 'N' (= "NO antenna assigned").
    let currentAntenna: Int?

    /// Current temperature scale value shown on the TEMP/FANS screen —
    /// "CELSIUS" or "FAHRENHEIT" (correctly spelled — earlier notes
    /// that called it "FARENHEIT" were wrong, confirmed 2026-05-07
    /// against a real 1.5K-FA capture). Nil on other screens.
    let temperatureScale: String?

    /// Current fan management value shown on the TEMP/FANS screen —
    /// typically "NORMAL" or "CONTEST". Nil on other screens.
    let fanManagement: String?

    /// Tunable-antenna status for [ANT1, ANT2, ANT3, ANT4] on the TUN ANT
    /// screen. Each entry is the text shown next to the antenna label
    /// (typically "NO" when not tunable, or "YES" / the band range when
    /// tunable). Nil on other screens.
    let tunAntStatuses: [String]?

    /// RX-only-antenna status for [ANT2, ANT3, ANT4] on the RX ANT screen.
    /// Same convention as `tunAntStatuses`: "NO" when not flagged RX-only,
    /// "YES" (or similar) when it is. Nil on other screens. Only 3 entries
    /// because ANT1 isn't an RX-only option on this amp family.
    let rxAntStatuses: [String]?

    /// Decoded alarm log entries visible on the ALARMS LOG screen.
    /// Each entry looks like `"10 IN1: SWR EXCEEDING LIMITS"` — a 1-based
    /// sequence number, input label (`IN<n>:`), and the alarm description.
    /// The amp's LCD shows the most-recent ~4 entries; scrolling on the amp
    /// changes which entries appear in subsequent frames. Nil on other
    /// screens.
    let alarmLogEntries: [String]?

    /// CAT-reported frequency on the MANUAL TUNE screen, e.g. "14.198".
    /// The MHZ unit is parsed separately. Nil on other screens or when CAT
    /// is set to NONE (amp can't report frequency).
    let manualTuneFrequency: String?

    /// Current L (inductance) value in µH shown on the MANUAL TUNE screen.
    let manualTuneL: String?

    /// Current C (capacitance) value in pF shown on the MANUAL TUNE screen.
    let manualTuneC: String?

    /// Short band label for whichever band the cursor is currently on
    /// inside the ANTENNA matrix screen — one of `"160M"`, `"80M"`, etc.
    /// Nil on other screens.
    let antennaCursorBand: String?

    /// Current antenna number / `"NO"` for the slot-1 of the cursored band,
    /// decoded from bytes 52-53 ("editing cell"). **Important caveat**:
    /// on the matrix VIEW (not edit sub-screen) this byte is unreliable —
    /// it tends to hold a stale/default value rather than the cursored
    /// band's real assignment. Use `antennaMatrixValues` instead for the
    /// per-band truth.
    let antennaCursorSlot1: String?

    /// Which slot of the cursored band the cursor is currently on — 1 or
    /// 2 — as parsed from the footer help text ("SET 1ST ANTENNA" vs
    /// "SET 2ND ANTENNA"). Nil on other screens or when the text doesn't
    /// clearly indicate a slot.
    let antennaCursorSlotIndex: Int?

    /// True when the amp's cursor is on the SAVE button at the bottom of
    /// the antenna matrix screen (rather than on a band/slot). Used to
    /// highlight SAVE in the MacExpert antenna view.
    let antennaCursorOnSave: Bool

    /// On the CAT baud rate screen — the CAT radio type currently
    /// configured (e.g. "YAESU", "KENWOOD", "TEN-TEC"). Nil off this screen.
    let baudRateCatType: String?

    /// On the CAT baud rate screen — the specific model selected (for
    /// YAESU and TEN-TEC) or "ALL" for radios without a model sub-menu.
    /// Nil off this screen.
    let baudRateModel: String?

    /// On the TUN ANT → PORT nested screen — the protocol name (e.g.
    /// "KENWOOD"), framing (data bit, stop bit, parity). All four are
    /// nil off this screen.
    let tunAntPortProtocol: String?
    let tunAntPortDataBit: String?
    let tunAntPortStopBit: String?
    let tunAntPortParity:  String?

    /// Parsed per-band antenna assignments from the ANTENNA matrix view.
    /// Keys are band labels ("160M", "80M", …). Each value is a
    /// `AntennaSlots` struct carrying slot1 and slot2 — typically `"NO"`
    /// or an antenna number possibly with a suffix (`"1b"`, `"2T"`, `"3r"`).
    ///
    /// The currently-cursored band's entry is **excluded by the view model**
    /// when merging into the learned map, because the cursor overlay masks
    /// its real value with "NO NO". Callers combine multiple frames (one
    /// per cursor position) to build a full 11-band picture.
    let antennaMatrixValues: [String: AntennaSlots]?

    /// Raw 367-byte payload, kept for future field extraction and debugging.
    let raw: [UInt8]

    // MARK: - Parsing

    /// Parse one 367-byte RCU display payload. Returns nil if the payload is
    /// too short to trust.
    static func parse(_ data: Data) -> RCUFrame? {
        guard data.count >= 320 else { return nil }
        let bytes = [UInt8](data)

        // Header: most screens fit their title in bytes 0-31, but a few
        // titles spill slightly past (e.g. "DISPLAY SETTINGS" loses its
        // final 's' at byte 32). Take a touch more to catch those.
        let header = LCDText.decodeTrimmed(bytes[0..<min(48, bytes.count)])
        let footer = bytes.count > 224
            ? LCDText.decodeTrimmed(bytes[224..<min(320, bytes.count)])
            : ""
        // Upper LCD region (bytes 0..192) — on some screens the title text
        // lives in the first 32 bytes (SETUP sub-menus), on others it's
        // lower (e.g. STANDBY's "EXPERT K-FA / SOLID STATE" are at ~64-160).
        let upperRegion = LCDText.decodeTrimmed(bytes[0..<min(192, bytes.count)])

        let antennaNotAvailable = bytes.count > 164
            && LCDText.contains(bytes[80..<min(164, bytes.count)],
                                text: "antenna not available")

        let screen = DetectedScreen.classify(header: header,
                                             upperRegion: upperRegion,
                                             footer: footer,
                                             antennaNotAvailable: antennaNotAvailable)

        // Bank letter lives at byte 33 only on screens with a "BANK X" title
        // (antenna matrix, manual tune, rx ant, tun ant). On SETUP root the
        // same byte is part of the "INPUT" text, so we'd decode a spurious
        // 'U'.
        let screensWithBankLetter: Set<DetectedScreen> = [
            .antennaMatrix, .manualTune, .rxAnt, .tunAnt,
        ]
        let bankLetter: Character? = {
            guard screensWithBankLetter.contains(screen), bytes.count > 33 else { return nil }
            // Fast path: byte 33 is where the bank letter usually lives on
            // these screens. Falls through to header-text parsing when the
            // byte-level decode doesn't yield A/B — some sub-screens (e.g.
            // the ANTENNA edit dialog) shift the letter elsewhere.
            if let fromByte = Self.decodeBankLetter(bytes[33]) {
                return fromByte
            }
            return Self.parseBankLetterFromHeader(header)
        }()

        let gridCursor: Int? = {
            switch screen {
            case .setupRoot:
                return GridCursorDecoder.decodeSetupRootCursor(bytes)
            case .catMenu:
                return GridCursorDecoder.decodeCATCursor(bytes)
            case .config:
                return GridCursorDecoder.decodeConfigCursor(bytes)
            case .tempFans:
                return GridCursorDecoder.decodeTempFansCursor(bytes)
            case .rxAnt:
                return GridCursorDecoder.decodeRxAntCursor(bytes)
            case .tunAnt:
                return GridCursorDecoder.decodeTunAntCursor(bytes)
            case .yaesuModel:
                return GridCursorDecoder.decodeYaesuModelCursor(bytes)
            case .tenTecModel:
                return GridCursorDecoder.decodeTenTecModelCursor(bytes)
            case .baudRate:
                return GridCursorDecoder.decodeBaudRateCursor(bytes)
            case .tunAntPort:
                return GridCursorDecoder.decodeTunAntPortCursor(bytes)
            default:
                return nil
            }
        }()

        let backlight = screen == .display ? decodeBacklightLevel(bytes) : nil
        let contrast = screen == .display ? decodeContrastLevel(bytes) : nil

        let configState = screen == .config ? decodeConfigState(bytes) : nil

        // The status-bar band/antenna readout is only meaningful on the
        // main OP screen (standby or operate) where that row is rendered.
        let (bandLabel, antenna) = screen.isMainScreen
            ? decodeStatusBar(bytes)
            : (nil, nil)

        // TEMP/FANS values: "CELSIUS"/"FARENHEIT" at bytes 108-122,
        // "NORMAL"/"CONTEST" at bytes 148-160. Empty string becomes nil.
        let temperatureScale: String? = {
            guard screen == .tempFans, bytes.count > 122 else { return nil }
            let s = LCDText.decodeTrimmed(bytes[108..<123])
            return s.isEmpty ? nil : s
        }()
        let fanManagement: String? = {
            guard screen == .tempFans, bytes.count > 160 else { return nil }
            let s = LCDText.decodeTrimmed(bytes[148..<161])
            return s.isEmpty ? nil : s
        }()

        // TUN ANT values: status text next to each antenna label.
        // Positions derived from the LCD layout:
        //     row 0:  ANT1 [95-100]    ANT3 [109-114]    PORT [—]
        //     row 1:  ANT2 [135-140]   ANT4 [149-154]    SAVE [—]
        let tunAntStatuses: [String]? = {
            guard screen == .tunAnt, bytes.count > 154 else { return nil }
            let a1 = LCDText.decodeTrimmed(bytes[95..<101])
            let a3 = LCDText.decodeTrimmed(bytes[109..<115])
            let a2 = LCDText.decodeTrimmed(bytes[135..<141])
            let a4 = LCDText.decodeTrimmed(bytes[149..<155])
            return [a1, a2, a3, a4].map { $0.isEmpty ? "—" : $0 }
        }()

        // RX ANT values: single column of 3 antennas (ANT2, ANT3, ANT4).
        // Status text byte ranges derived from the LCD render:
        //     ANT2: ~101-105   ANT3: ~141-145   ANT4: ~181-185
        let rxAntStatuses: [String]? = {
            guard screen == .rxAnt, bytes.count > 185 else { return nil }
            let a2 = LCDText.decodeTrimmed(bytes[101..<106])
            let a3 = LCDText.decodeTrimmed(bytes[141..<146])
            let a4 = LCDText.decodeTrimmed(bytes[181..<186])
            return [a2, a3, a4].map { $0.isEmpty ? "—" : $0 }
        }()

        // ALARMS LOG entries: bytes 32-191 are the entry area. Entries flow
        // left-to-right, top-to-bottom across the 5 LCD rows and wrap mid-
        // word. Each entry starts with an index number followed by "IN<n>:"
        // and the alarm description, e.g. "10 IN1: SWR EXCEEDING LIMITS".
        let alarmLogEntries: [String]? = {
            guard screen == .alarmsLog, bytes.count > 192 else { return nil }
            return parseAlarmLog(bytes: bytes, range: 32..<192)
        }()

        // MANUAL TUNE numeric readouts, decoded from the LCD text. We use
        // `decode` (not `decodeTrimmed`) because the latter collapses '.'
        // into spaces, which would break numbers like "14.198". Then we
        // extract the first numeric run (integer or decimal) via regex.
        let mtFreq = (screen == .manualTune && bytes.count > 62)
            ? Self.extractNumber(LCDText.decode(bytes[50..<62]))
            : nil
        let mtL = (screen == .manualTune && bytes.count > 121)
            ? Self.extractNumber(LCDText.decode(bytes[114..<122]))
            : nil
        let mtC = (screen == .manualTune && bytes.count > 161)
            ? Self.extractNumber(LCDText.decode(bytes[154..<162]))
            : nil

        // ANTENNA matrix: parse the currently-cursored band (from the
        // context-help text in the footer) and the unreliable byte-52
        // slot-1 value (kept for diagnostics). The real per-band values
        // come from parsing the matrix text layout; see below.
        let antCursor: (band: String?, slot1: String?, slotIndex: Int?, onSave: Bool) = {
            guard screen == .antennaMatrix, bytes.count > 224 else {
                return (nil, nil, nil, false)
            }
            let searchRange = 224..<min(320, bytes.count)
            let searchText = LCDText.decodeTrimmed(bytes[searchRange])
            let band = Self.parseAntennaBandLabel(searchText)
            let slot1Byte = bytes.count > 53 ? bytes[52] : 0
            let slot1NextByte = bytes.count > 53 ? bytes[53] : 0
            let slot1 = Self.parseAntennaSlotValue(b1: slot1Byte, b2: slot1NextByte)
            let slotIdx = Self.parseAntennaSlotIndex(searchText)
            // Heuristic: when the footer hints don't name a band or a
            // slot index, the cursor is on the SAVE button. The amp's
            // cursor footer changes to a prompt like "[SET]: SAVE" in
            // that case, leaving parseAntennaBandLabel / SlotIndex both
            // nil. Require the footer to actually mention SAVE so this
            // doesn't false-positive on a malformed frame.
            let onSave = band == nil && slotIdx == nil
                && searchText.uppercased().contains("SAVE")
            return (band, slot1, slotIdx, onSave)
        }()

        // Parse the full antenna matrix from the LCD's text layout. Each
        // band appears as "<band> M: <slot1> <slot2>" and we regex out
        // all 11 bands in one pass.
        let antMatrix: [String: AntennaSlots]? = {
            guard screen == .antennaMatrix, bytes.count > 192 else { return nil }
            return Self.parseAntennaMatrixValues(bytes: bytes)
        }()

        // Baud rate screen — decode "CAT <type>" and "TYPE <model>"
        // labels from the left half of the LCD. Scan bytes 32-127 which
        // covers both label lines.
        let (brCat, brModel): (String?, String?) = {
            guard screen == .baudRate, bytes.count > 128 else { return (nil, nil) }
            // Real scan looks like:
            //   "SET CAT BAUD RATE ON INPUT 1 CAT : TEN TEC 1200 19200 TYPE: OMNI VII 2400 38400"
            // The right-column baud digits are interleaved into the scanned
            // string, so we can't just grab "word after keyword" — we need
            // to stop at the first digit run or at the next keyword.
            let text = LCDText.decodeTrimmed(bytes[0..<min(192, bytes.count)])
            let stripped: String = {
                if let r = text.range(of: "SET CAT BAUD RATE", options: .caseInsensitive) {
                    return String(text[r.upperBound...])
                }
                return text
            }()
            let bauds: Set<String> = ["1200","2400","4800","9600","19200","38400","57600","115200"]
            func grab(after keyword: String, in s: String) -> String? {
                guard let r = s.range(of: keyword, options: .caseInsensitive) else { return nil }
                var rest = Substring(s[r.upperBound...])
                while let c = rest.first, c == ":" || c == " " { rest = rest.dropFirst() }
                // Keep tokens until we see (a) another keyword, or (b) a
                // pure-digit token that matches a known baud rate. A
                // pure-digit token like "847" in "FT817/847" (the / decoded
                // as space) is still part of the model.
                let tokens = rest.split(separator: " ").map(String.init)
                var kept: [String] = []
                for t in tokens {
                    let upper = t.uppercased()
                    if upper == "TYPE" || upper == "CAT" { break }
                    if bauds.contains(t) { break }
                    kept.append(t)
                }
                let joined = kept.joined(separator: " ")
                return joined.isEmpty ? nil : joined
            }
            return (grab(after: "CAT", in: stripped),
                    grab(after: "TYPE", in: stripped))
        }()

        // TUN ANT → PORT screen — protocol/framing labels on the left half
        // alongside the 4×2 baud grid on the right.
        //   "TUNEABLE ANTENNAS PORT PROTOCOL: KENWOOD 1200 19200
        //    DATA BIT: 8  2400 38400  STOP BIT: 1  4800 57600
        //    PARITY: NONE 9600 115200"
        // Same interleave problem as baud rate — grab tokens after each
        // keyword, stop at a known baud rate, numeric stop-bit/data-bit
        // values are single digits so we also stop at any whitespace after
        // a plausible value. Simplest: keep alphanumeric tokens until a
        // pure-digit token that matches a baud rate or the next keyword.
        let (tpProto, tpData, tpStop, tpParity): (String?, String?, String?, String?) = {
            guard screen == .tunAntPort, bytes.count > 192 else { return (nil, nil, nil, nil) }
            let text = LCDText.decodeTrimmed(bytes[0..<min(224, bytes.count)])
            let bauds: Set<String> = ["1200","2400","4800","9600","19200","38400","57600","115200"]
            let nextKeywords: Set<String> = ["PROTOCOL","DATA","STOP","PARITY","BIT"]
            func grab(after keyword: String, in s: String, singleValue: Bool = false) -> String? {
                guard let r = s.range(of: keyword, options: .caseInsensitive) else { return nil }
                var rest = Substring(s[r.upperBound...])
                while let c = rest.first, c == ":" || c == " " { rest = rest.dropFirst() }
                let tokens = rest.split(separator: " ").map(String.init)
                var kept: [String] = []
                for t in tokens {
                    if nextKeywords.contains(t.uppercased()) { break }
                    if bauds.contains(t) { break }
                    kept.append(t)
                    if singleValue { break }   // data/stop/parity are one-token
                }
                let j = kept.joined(separator: " ")
                return j.isEmpty ? nil : j
            }
            return (
                grab(after: "PROTOCOL", in: text),
                grab(after: "DATA BIT", in: text, singleValue: true),
                grab(after: "STOP BIT", in: text, singleValue: true),
                grab(after: "PARITY",   in: text, singleValue: true)
            )
        }()

        return RCUFrame(
            screen: screen,
            header: header,
            footer: footer,
            bankLetter: bankLetter,
            gridCursorNavIndex: gridCursor,
            backlightLevel: backlight,
            contrastLevel: contrast,
            configState: configState,
            antennaNotAvailable: antennaNotAvailable,
            currentBandLabel: bandLabel,
            currentAntenna: antenna,
            temperatureScale: temperatureScale,
            fanManagement: fanManagement,
            tunAntStatuses: tunAntStatuses,
            rxAntStatuses: rxAntStatuses,
            alarmLogEntries: alarmLogEntries,
            manualTuneFrequency: mtFreq,
            manualTuneL: mtL,
            manualTuneC: mtC,
            antennaCursorBand: antCursor.band,
            antennaCursorSlot1: antCursor.slot1,
            antennaCursorSlotIndex: antCursor.slotIndex,
            antennaCursorOnSave: antCursor.onSave,
            baudRateCatType: brCat,
            baudRateModel: brModel,
            tunAntPortProtocol: tpProto,
            tunAntPortDataBit: tpData,
            tunAntPortStopBit: tpStop,
            tunAntPortParity:  tpParity,
            antennaMatrixValues: antMatrix,
            raw: bytes
        )
    }

    /// Find which slot (1 or 2) is currently selected on the ANTENNA matrix
    /// screen, by looking for "1ST ANTENNA" or "2ND ANTENNA" in the footer
    /// help text. Returns nil when the text doesn't make a clear claim.
    static func parseAntennaSlotIndex(_ text: String) -> Int? {
        let upper = text.uppercased()
        if upper.contains("1ST ANTENNA") { return 1 }
        if upper.contains("2ND ANTENNA") { return 2 }
        return nil
    }

    /// Find any valid band label ("160M", "20M", etc.) as a substring of
    /// the given text. Used on the ANTENNA matrix screen where the
    /// currently-cursored band is named in the footer's context-help text
    /// (e.g. "SET 1ST ANTENNA ON 160M BAND").
    ///
    /// Iterates longest label first so `"60M"` can't false-positive inside
    /// `"160M"` — if `"160M"` is present it wins the lookup before we
    /// consider `"60M"` at all.
    static func parseAntennaBandLabel(_ text: String) -> String? {
        let upper = text.uppercased()
        let bandsByPriority = [
            "160M", "80M", "60M", "40M", "30M",
            "20M", "17M", "15M", "12M", "10M", "6M",
        ]
        for band in bandsByPriority {
            if upper.contains(band) {
                return band
            }
        }
        return nil
    }

    /// Decode the "editing cell" two-byte slot value at bytes 52-53 of an
    /// ANTENNA matrix frame. The first byte is the antenna designator and
    /// the second is an optional suffix flag that encodes the antenna's
    /// tuner/RX-only status.
    ///
    /// Known encodings:
    ///   0x2E 0x2F → "NO"   (slot unassigned)
    ///   0x11-0x14 → "1"-"4" for the antenna number
    /// Suffix flag (byte 2):
    ///   0x00      → no suffix (internal tuner active)
    ///   "B"/"b"   → "b" (internal tuner bypassed)
    ///   "T"/"t"   → "t" (external tunable antenna)
    ///   "R"/"r"   → "r" (RX-only antenna)
    ///   anything else: appended as-is if it decodes to a printable char.
    /// Examples: `"1"`, `"1b"`, `"2t"`, `"3r"`, `"NO"`.
    /// Returns nil if the primary byte doesn't match any known encoding.
    static func parseAntennaSlotValue(b1: UInt8, b2: UInt8) -> String? {
        if b1 == 0x2E && b2 == 0x2F { return "NO" }
        guard (0x11...0x14).contains(b1) else { return nil }
        let num = String(b1 - 0x10)
        // Decode suffix byte (if present). Use the same attribute XOR
        // convention as LCDText for consistency.
        if b2 == 0x00 { return num }
        let suffixChar: Character? = {
            if b2 >= 0x10 && b2 <= 0x3F {
                return Character(UnicodeScalar(b2 + 0x20))
            }
            if b2 >= 0x40 && b2 <= 0x7E {
                return Character(UnicodeScalar(b2))
            }
            return nil
        }()
        guard let ch = suffixChar else { return num }
        // Normalize suffixes to lowercase: "b" (bypassed), "t" (tunable),
        // "r" (RX-only). Matches the amp's LCD which shows them lowercase.
        let normalized: String = {
            let lowered = ch.lowercased()
            switch lowered {
            case "b": return "b"   // internal tuner bypassed
            case "r": return "r"   // RX-only antenna
            case "t": return "t"   // external tunable antenna
            default:  return String(ch)
            }
        }()
        return num + normalized
    }

    /// Extract the first numeric value (integer or decimal) from a decoded
    /// LCD string, preserving any embedded decimal point. Returns nil if
    /// no digits are present. Used for MANUAL TUNE readouts where numbers
    /// like "14.198" or "0.00" appear alongside unit text or null padding.
    static func extractNumber(_ raw: String) -> String? {
        let pattern = "\\d+(?:\\.\\d+)?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, range: nsRange),
              let range = Range(match.range, in: raw) else {
            return nil
        }
        return String(raw[range])
    }

    /// Parse the alarm-log entry area (bytes 32-191) into individual
    /// entries. Entries flow across LCD rows and wrap mid-word, so we
    /// decode the whole region as a single string then split on the
    /// "N IN<n>:" pattern that begins each entry.
    static func parseAlarmLog(bytes: [UInt8], range: Range<Int>) -> [String] {
        let raw = LCDText.decodeTrimmed(bytes[range])
        let tokens = raw.components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        let normalized = tokens.joined(separator: " ")
        guard !normalized.isEmpty else { return [] }

        // Regex: each entry = an index (digits + optional dot) + whitespace +
        // "IN<n>:" + content up to (but not including) the next entry or EOS.
        let pattern = #"\d+\.?\s+IN\d+:\s*[^0-9]*?(?=\s+\d+\.?\s+IN\d+:|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        let matches = regex.matches(in: normalized, range: nsRange)
        return matches.compactMap { m in
            guard let r = Range(m.range, in: normalized) else { return nil }
            return String(normalized[r]).trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: - Private field decoders

    /// Parse the ANTENNA matrix LCD area into a band → (slot1, slot2) map.
    /// The matrix text looks like:
    ///   "160 M: NO NO  30 M: 3 NO  12 M: 2 NO  80 M: 1 NO  20 M: 2 NO  …"
    /// We regex-match every `<digits> M: <val1> <val2>` tuple. Values keep
    /// whatever suffix the amp renders (`b`, `T`, `r`).
    static func parseAntennaMatrixValues(bytes: [UInt8]) -> [String: AntennaSlots] {
        let searchEnd = min(192, bytes.count)
        guard searchEnd > 32 else { return [:] }
        let text = LCDText.decodeTrimmed(bytes[32..<searchEnd])

        // Pattern: band number, " M:", whitespace, slot1 token, whitespace,
        // slot2 token. `\S+` captures "NO", "1", "2T", etc.
        let pattern = #"(\d+)\s+M:\s+(\S+)\s+(\S+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var result: [String: AntennaSlots] = [:]
        for match in regex.matches(in: text, range: nsRange) {
            guard match.numberOfRanges == 4,
                  let r1 = Range(match.range(at: 1), in: text),
                  let r2 = Range(match.range(at: 2), in: text),
                  let r3 = Range(match.range(at: 3), in: text)
            else { continue }
            let band = String(text[r1]) + "M"
            result[band] = AntennaSlots(
                slot1: normalizeSlotLabel(String(text[r2])),
                slot2: normalizeSlotLabel(String(text[r3]))
            )
        }
        return result
    }

    /// Normalize a slot-label token so the suffix letter matches our display
    /// convention: lowercase `b` / `t` / `r`. `"NO"` and plain antenna
    /// numbers pass through unchanged. Input can come in with either case
    /// thanks to the amp's mix of attributed and normal ASCII encodings.
    private static func normalizeSlotLabel(_ s: String) -> String {
        guard s.count == 2,
              let first = s.first, first.isNumber,
              let last = s.last, last.isLetter
        else { return s }
        let lower = last.lowercased()
        switch lower {
        case "b": return "\(first)b"
        case "r": return "\(first)r"
        case "t": return "\(first)t"
        default:  return s
        }
    }

    /// Find `keyword` in `text` and return the first whitespace-delimited
    /// token that follows it. Used for parsing "CAT YAESU", "TYPE FT100",
    /// etc. from decoded LCD text. Uppercased. Nil if keyword not present
    /// or nothing follows.
    static func extractFollowing(keyword: String, in text: String) -> String? {
        let upper = text.uppercased()
        guard let range = upper.range(of: keyword) else { return nil }
        let after = upper[range.upperBound...]
        // Skip leading whitespace, then grab next whitespace-delimited word.
        let trimmed = after.drop(while: { $0.isWhitespace })
        let token = trimmed.prefix(while: { !$0.isWhitespace })
        let result = String(token)
        return result.isEmpty ? nil : result
    }

    /// Fallback bank-letter extractor: looks for the substring "BANK <X>"
    /// in the decoded header text and returns the X if it's A or B.
    static func parseBankLetterFromHeader(_ header: String) -> Character? {
        let upper = header.uppercased()
        guard let range = upper.range(of: "BANK ") else { return nil }
        let after = upper[range.upperBound...]
        guard let first = after.first else { return nil }
        return (first == "A" || first == "B") ? first : nil
    }

    private static func decodeBankLetter(_ b: UInt8) -> Character? {
        // Only accept A or B, in either attributed or normal encoding.
        // Other single-letter bytes at position 33 could be text from
        // header/title rather than a bank letter, so we don't want to
        // be promiscuous here.
        switch b {
        case 0x21: return "A"     // attributed 'A' (+0x20 = 0x41)
        case 0x22: return "B"     // attributed 'B' (+0x20 = 0x42)
        case 0x41: return "A"     // normal ASCII 'A'
        case 0x42: return "B"     // normal ASCII 'B'
        default:   return nil
        }
    }

    /// Backlight bar on the DISPLAY screen, bytes 100-116 of the RCU frame.
    /// The bar is rendered with custom LCD glyphs at each end:
    ///   - Left cap: values 0x92-0x97 encode progressive fill (0x92=min, 0x97=max).
    ///   - Right cap: values 0x94-0x98 encode progressive emptiness (0x94=full, 0x98=empty).
    ///   - Middle: 0x93 = empty cell (padding).
    /// We derive a 0-6 normalized level from the left-cap glyph, which has
    /// the cleanest monotonic mapping.
    static let backlightRange = 100..<117

    private static func decodeBacklightLevel(_ bytes: [UInt8]) -> Int? {
        guard bytes.count > backlightRange.upperBound else { return nil }
        return decodeBarLevel(bytes: bytes, range: backlightRange)
    }

    /// Contrast bar range — between the "[◀C]" and "[C▶]" markers on the
    /// DISPLAY screen. The marker itself ends around byte 179 (the `]`
    /// character), so the bar proper starts at byte 180.
    static let contrastRange = 180..<196

    private static func decodeContrastLevel(_ bytes: [UInt8]) -> Int? {
        guard bytes.count > contrastRange.upperBound else { return nil }
        return decodeBarLevel(bytes: bytes, range: contrastRange)
    }

    /// Derive a 0-9 level from the bar byte range using the cap glyphs only.
    ///
    /// Empirically (verified 2026-04-17 with "backlight off = minimum"
    /// confirmation from the amp's physical display), the cap encoding
    /// direction is:
    ///   - Left cap 0x97 + right cap 0x94 → OFF / minimum brightness.
    ///   - Left cap 0x92 + right cap 0x98 → full / maximum brightness.
    /// So larger cap byte values indicate LESS brightness. We invert the
    /// raw cap sum to produce a "0 = off, 9 = max" scale matching what
    /// the user expects.
    ///
    /// The 0x96 cursor glyph that sometimes appears in the middle of the
    /// bar is deliberately ignored; it's a transient editing indicator
    /// that caused direction inversions when we tried to use it as a
    /// fine-grained offset.
    private static func decodeBarLevel(bytes: [UInt8], range: Range<Int>) -> Int? {
        let slice = Array(bytes[range])
        let leftCap = slice.first { $0 != 0x93 && $0 != 0x96 }
        let rightCap = slice.reversed().first { $0 != 0x93 && $0 != 0x96 }
        guard leftCap != nil || rightCap != nil else { return nil }

        // leftAmount rises from 0 (cap=0x92) to 5 (cap=0x97).
        let leftAmount: Int = leftCap.map {
            max(0, min(5, Int($0) - 0x92))
        } ?? 0
        // rightAmount rises from 0 (cap=0x98) to 4 (cap=0x94).
        let rightAmount: Int = rightCap.map {
            max(0, min(4, 0x98 - Int($0)))
        } ?? 0
        // Combined 0..9: 9 = "max cap byte values" = OFF. Invert for display.
        let capSum = leftAmount + rightAmount
        return barLevelMax - capSum
    }

    /// Max value from `decodeBarLevel` on a brightness scale: 0 = off, 9 = full.
    static let barLevelMax = 9

    /// 5 specific bytes hold the checkbox/radio state glyph (0xAE=filled).
    private static func decodeConfigState(_ bytes: [UInt8]) -> ConfigState? {
        guard bytes.count > 183 else { return nil }
        func filled(_ i: Int) -> Bool { bytes[i] == 0xAE }
        return ConfigState(
            bankA: filled(88),
            bankB: filled(128),
            remoteAntSwitch: filled(103),
            so2rMatrix: filled(143),
            combiner: filled(183)
        )
    }

    /// The normal-display status bar encodes the band across bytes 289-291
    /// (first digit, second digit, trailing '0') and antenna at byte 295.
    private static func decodeStatusBar(_ bytes: [UInt8]) -> (band: String?, antenna: Int?) {
        guard bytes.count > 295 else { return (nil, nil) }

        // Band label: decode bytes 289-291 as attributed text, trim nulls.
        let bandRaw = LCDText.decode(bytes[289..<292])
        let bandClean = bandRaw
            .replacingOccurrences(of: ".", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let band = bandClean.isEmpty ? nil : bandClean

        // Antenna: byte 295 is '1'-'4' when assigned, 'N' (from "NO") otherwise.
        let a295 = bytes[295]
        let antenna: Int?
        if a295 >= 0x11, a295 <= 0x14 {
            antenna = Int(a295 - 0x10)
        } else {
            antenna = nil
        }

        return (band, antenna)
    }
}

/// The two antenna slots rendered for a band on the ANTENNA matrix screen.
/// `"NO"` = unassigned; otherwise an antenna number (1-4) optionally with a
/// suffix flag: `"b"` = ATU bypassed, `"t"` = external tunable antenna,
/// `"r"` = RX-only.
struct AntennaSlots: Equatable {
    let slot1: String
    let slot2: String
}

/// Checkbox + bank radio state for the CONFIG ("OTHER SETTINGS") sub-menu.
struct ConfigState: Equatable {
    let bankA: Bool
    let bankB: Bool
    let remoteAntSwitch: Bool
    let so2rMatrix: Bool
    let combiner: Bool
}

/// Every LCD screen MacExpert can currently recognize. Detection is by the
/// header text decoded from bytes 0-31 (plus the "antenna not available"
/// overlay, which takes precedence).
enum DetectedScreen: String, Equatable {
    case setupRoot
    case antennaMatrix
    case catMenu
    case yaesuModel       // CAT → YAESU → 14-model picker
    case tenTecModel      // CAT → TEN-TEC → 4-model picker
    case baudRate
    case alarmsLog
    case display
    case tempFans
    case manualTune
    case rxAnt
    case tunAnt
    case tunAntPort       // Nested: TUN ANT → PORT — protocol/framing + baud grid
    case config
    case opStandby        // Main screen in STANDBY (logo / welcome text in header)
    case opOperate        // Main screen in OPERATE (power-scale tick marks 0/125/250/375/500 in header)
    case antennaNotAvailable
    /// Read-only info screens brought up by CAT / DISP button presses on
    /// the main screen. The amp cycles through several (CAT settings,
    /// system info, serial number, BIAS CHECK, etc.) as the user keeps
    /// pressing. We render them as a generic decoded-LCD-text block
    /// since they have no cursor and no editable fields.
    case infoScreen
    case unknown

    /// Either of the two main operate screens (standby or operate). Both
    /// share the status-bar footer.
    var isMainScreen: Bool { self == .opStandby || self == .opOperate }

    /// Classify by decoded text. Sub-menu screens are identified by the
    /// narrow header (bytes 0-31). The two main screens (standby/operate)
    /// have distinctive markers that may live further down the LCD, so we
    /// also scan the upper region (bytes 0-192).
    static func classify(header: String,
                         upperRegion: String,
                         footer: String,
                         antennaNotAvailable: Bool) -> DetectedScreen {
        if antennaNotAvailable { return .antennaNotAvailable }
        let h = header.lowercased()
        // Use shorter, unambiguous substrings so a truncated-at-32 header
        // still matches (e.g. "DISPLAY SETTING" without trailing 's').
        if h.contains("setup option")         { return .setupRoot }
        if h.contains("set antenna on bank")  { return .antennaMatrix }
        if h.contains("set yaesu model")      { return .yaesuModel }
        if h.contains("set ten") || h.contains("set tentec") { return .tenTecModel }
        if h.contains("set cat interface")    { return .catMenu }
        if h.contains("set cat baud")         { return .baudRate }
        if h.contains("alarms log")           { return .alarmsLog }
        if h.contains("display setting")      { return .display }
        if h.contains("temperature and fan")  { return .tempFans }
        if h.contains("manual tune on bank")  { return .manualTune }
        if h.contains("rx only antenna")      { return .rxAnt }
        // Nested PORT screen sits under TUN ANT — match it before the
        // plain tunAnt matcher so "antennas port" wins.
        if h.contains("antennas port") ||
           h.contains("tuneable antenna") && h.contains("port") { return .tunAntPort }
        if h.contains("tunable antenna") ||
           h.contains("tuneable antenna")    { return .tunAnt }
        if h.contains("other setting")        { return .config }

        let u = upperRegion.lowercased()

        // CAT / DISP info screens — no cursor, just read-only panels
        // brought up by repeated CAT / DISP presses in STANDBY/OPERATE.
        // Match distinctive headers reported in the memory:
        //   STANDBY + CAT:  "CAT SETTINGS", "SYSTEM INFO", "FIRMWARE"
        //   STANDBY + DISP: "SERIAL NUMBER", "HARDWARE NUMBER", "CAL"
        //   OPERATE + CAT:  "BIAS CHECK"
        //   OPERATE + DISP: fan/SWR/temp overview (header TBD).
        //
        // Some info screens (notably the DISP cycle) put their title in
        // the BODY rather than the header row, so scan both. This runs
        // *before* the STANDBY/OPERATE classifiers below because those
        // use broad markers like "EXPERT" which the serial-number info
        // screen also contains.
        // DISP info screens on the 1.5K-FA overlay the standby body with
        // a small key:value suffix — "SN:0656", "HW: 026", "CAL:002" —
        // rather than replacing the whole screen. Match those colon-form
        // markers alongside the proper-name CAT info headers.
        let infoMarkers = [
            "cat setting", "system info", "firmware",
            "serial number", "hardware number",
            "sn:", "hw:", "cal:",
            "bias check", "release", "fw ver", "hw ver",
        ]
        for marker in infoMarkers {
            if h.contains(marker) || u.contains(marker) {
                return .infoScreen
            }
        }

        // STANDBY main screen: "EXPERT K-FA / SOLID STATE / FULLY
        // AUTOMATIC / STANDBY" appears at around bytes 64-160.
        if u.contains("standby") || u.contains("solid state") ||
           u.contains("fully automatic") || u.contains("expert") {
            return .opStandby
        }

        // OPERATE main screen: the power scale "0 125 250 375 500" renders
        // along the top of the LCD. The mid-scale numbers are distinctive.
        if u.contains("125") || u.contains("250") || u.contains("375") {
            return .opOperate
        }

        // Fallback: any screen whose footer looks like the status bar is
        // a main screen of some kind. Default to operate.
        let f = footer.lowercased()
        if f.contains("band") && f.contains("ant") && f.contains("bnk") {
            return .opOperate
        }

        return .unknown
    }
}
