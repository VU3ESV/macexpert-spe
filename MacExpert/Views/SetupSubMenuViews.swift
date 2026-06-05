import SwiftUI

// MARK: - Shared LCD Styling

enum LCDStyle {
    static let green = Color(red: 0.2, green: 0.9, blue: 0.2)
    static let dimGreen = Color(red: 0.1, green: 0.4, blue: 0.1)
    static let background = Color(red: 0.02, green: 0.06, blue: 0.02)
    static let font = Font.system(size: 13, weight: .medium, design: .monospaced)
    static let fontBold = Font.system(size: 14, weight: .bold, design: .monospaced)
    static let fontSmall = Font.system(size: 11, weight: .medium, design: .monospaced)
}

/// Shared LCD container wrapper. Every sub-menu renders inside one of
/// these, so enforcing a fixed content height here keeps the whole
/// screen area the same size regardless of which menu is active. That
/// preserves mouse-click hit areas and avoids the UI below jumping
/// around when the user navigates between menus.
struct LCDContainer<Content: View>: View {
    let title: String
    var subtitle: String = ""
    let hintLeft: String
    let hintRight: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(LCDStyle.fontBold)
                    .foregroundStyle(LCDStyle.green)
                Spacer()
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(LCDStyle.font)
                        .foregroundStyle(LCDStyle.dimGreen)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Rectangle().fill(LCDStyle.dimGreen).frame(height: 1).padding(.horizontal, 8)

            // Body takes whatever vertical space the caller gives us
            // (via an outer .frame). ContentView sizes every sub-menu
            // to match PowerDisplay+Gauges so switching doesn't shift
            // the rest of the UI. Content is top-aligned; any unused
            // space sits below as empty LCD area.
            VStack(spacing: 0) {
                content()
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)

            Rectangle().fill(LCDStyle.dimGreen).frame(height: 1).padding(.horizontal, 8)

            HStack {
                Text(hintLeft)
                    .font(LCDStyle.fontSmall)
                    .foregroundStyle(LCDStyle.dimGreen)
                Spacer()
                Text(hintRight)
                    .font(LCDStyle.fontSmall)
                    .foregroundStyle(LCDStyle.dimGreen)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(LCDStyle.background))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(LCDStyle.dimGreen.opacity(0.3), lineWidth: 1))
        .shadow(color: LCDStyle.green.opacity(0.08), radius: 8)
    }
}

/// Highlighted/normal LCD text item
struct LCDItem: View {
    let label: String
    var isSelected: Bool = false

    var body: some View {
        Text(label)
            .font(LCDStyle.font)
            .foregroundStyle(isSelected ? .black : LCDStyle.green)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 2).fill(isSelected ? LCDStyle.green : Color.clear))
    }
}

///// Read-only "KEY : VALUE" row shared across all sub-menus that surface
/// amp-reported settings (PROTOCOL : KENWOOD, CAT : YAESU, TYPE : FT100,
/// DATA BIT : 8, etc.). One helper keeps fonts, colons, and alignment
/// identical everywhere.
struct LCDKeyValue: View {
    let key: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(key.uppercased())
                .font(LCDStyle.font)
                .foregroundStyle(LCDStyle.green)
            Text(":")
                .font(LCDStyle.font)
                .foregroundStyle(LCDStyle.green)
            Text(value)
                .font(LCDStyle.font)
                .foregroundStyle(LCDStyle.green)
        }
    }
}

// Checkbox-style LCD item: [ ] or [v]
struct LCDCheckbox: View {
    let label: String
    var isChecked: Bool = false
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 2) {
            Text(isChecked ? "[v]" : "[ ]")
                .font(LCDStyle.font)
                .foregroundStyle(isSelected ? .black : LCDStyle.green)
            Text(label)
                .font(LCDStyle.font)
                .foregroundStyle(isSelected ? .black : LCDStyle.green)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 2).fill(isSelected ? LCDStyle.green : Color.clear))
    }
}

// MARK: - CONFIG Sub-Menu
// Items (nav order): BNK A(0), BNK B(1), REMOTE ANT(2), SO2R(3), COMBINER(4), SAVE(5)

struct ConfigSubMenuView: View {
    @Environment(AmplifierViewModel.self) private var vm

    var body: some View {
        let cursor = vm.subMenuCursorIndex
        // Prefer live state from the parsed RCU frame; fall back to the
        // CSV-derived memBank for BNK A/B when no frame is available.
        let cfg = vm.rcuFrame?.configState
        let bankA = cfg?.bankA ?? (vm.state.memBank == "A")
        let bankB = cfg?.bankB ?? (vm.state.memBank == "B" || vm.state.memBank == "x")
        let remoteAnt = cfg?.remoteAntSwitch ?? false
        let so2r = cfg?.so2rMatrix ?? false
        let combiner = cfg?.combiner ?? false

        LCDContainer(
            title: "CONFIG",
            hintLeft: "[\u{25C0}\u{25B6}]: SELECT",
            hintRight: "[SET]: CHANGE"
        ) {
            VStack(spacing: 4) {
                HStack {
                    LCDCheckbox(label: "BNK A", isChecked: bankA, isSelected: cursor == 0)
                    Spacer()
                    LCDCheckbox(label: "REMOTE ANT SWITCH", isChecked: remoteAnt, isSelected: cursor == 2)
                }
                HStack {
                    LCDCheckbox(label: "BNK B", isChecked: bankB, isSelected: cursor == 1)
                    Spacer()
                    LCDCheckbox(label: "SO2R MATRIX", isChecked: so2r, isSelected: cursor == 3)
                }
                HStack {
                    Spacer()
                    LCDCheckbox(label: "COMBINER", isChecked: combiner, isSelected: cursor == 4)
                }
                HStack {
                    Spacer()
                    LCDItem(label: "SAVE", isSelected: cursor == 5)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - ANTENNA Sub-Menu
// Auto-learns from CSV status. Tap a band to manually set its antenna (cycles 1→2→3→4→NO).

struct AntennaSubMenuView: View {
    @Environment(AmplifierViewModel.self) private var vm

    // Display order matches amp panel: 160m, 80m, 60m, 40m, 30m, 20m,
    // 17m, 15m, 12m, 10m, 6m. Short labels ("160M", "80M") match the
    // ANTENNA cursor band inset so we can key into `vm.antennaMatrix`.
    private let bandLabels: [(display: String, key: String)] = [
        ("160m", "160M"), ("80m", "80M"), ("60m", "60M"), ("40m", "40M"),
        ("30m", "30M"), ("20m", "20M"), ("17m", "17M"), ("15m", "15M"),
        ("12m", "12M"), ("10m", "10M"), ("6m", "6M"),
    ]

    var body: some View {
        // The bank letter from the currently-parsed antenna frame — falls
        // back to the CSV memBank when no frame is available yet.
        let bank = vm.rcuFrame?.bankLetter.map { String($0) }
            ?? (vm.state.memBank.isEmpty ? "?" : vm.state.memBank)
        let cursorBand = vm.rcuFrame?.antennaCursorBand

        LCDContainer(
            title: "SET ANTENNA",
            subtitle: "BANK \"\(bank)\"",
            hintLeft: "[\u{25C0}\u{25B6}]: SELECT BAND",
            hintRight: "[SET]: CHANGE ANT"
        ) {
            VStack(spacing: 6) {
                // Per-band matrix. Green highlight = amp's currently-cursored
                // band. Gold highlight = MacExpert's "currently active"
                // transmit band from CSV.
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(0..<4, id: \.self) { i in
                            row(bandLabels[i], bank: bank, cursorBand: cursorBand)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(4..<8, id: \.self) { i in
                            row(bandLabels[i], bank: bank, cursorBand: cursorBand)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(8..<11, id: \.self) { i in
                            row(bandLabels[i], bank: bank, cursorBand: cursorBand)
                        }
                    }
                }

                // SAVE row — mirrors the amp's SAVE button at the bottom of
                // the matrix. We don't currently have a cursor signal that
                // tells us when the amp is on SAVE (bands + slot1/slot2 is
                // all we decode), so SAVE is a plain action here: tapping
                // it sends a SET command so the user can commit matrix
                // edits without reaching for the physical SET button.
                HStack {
                    Spacer()
                    LCDItem(label: "SAVE",
                            isSelected: vm.rcuFrame?.antennaCursorOnSave == true)
                        .onTapGesture { vm.sendCommand(.set) }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func row(_ label: (display: String, key: String), bank: String, cursorBand: String?) -> some View {
        let slots = vm.antennaMatrix["\(bank)/\(label.key)"]
        let isCursored = cursorBand == label.key
        let isCurrentBand = vm.state.band == label.display
        // Which slot the user is actively changing, if we can tell.
        let cursorSlotIndex = isCursored ? vm.rcuFrame?.antennaCursorSlotIndex : nil

        HStack(spacing: 3) {
            Text("\(label.display):")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(isCurrentBand ? .orange : LCDStyle.dimGreen)
                .frame(width: 44, alignment: .trailing)
            // Two separately-highlightable slot cells so the user can see
            // which one the amp cursor is on (slot 1 vs slot 2).
            slotCell(text: slots?.slot1 ?? "?", highlight: cursorSlotIndex == 1)
            slotCell(text: slots?.slot2 ?? "?", highlight: cursorSlotIndex == 2)
        }
    }

    @ViewBuilder
    private func slotCell(text: String, highlight: Bool) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .foregroundStyle(highlight ? .black : LCDStyle.green)
            .frame(width: 32)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(highlight ? LCDStyle.green : Color.clear)
            )
    }
}

// MARK: - CAT Sub-Menu
// Items (column-first): NONE(0), ICOM(1), KENWOOD(2), YAESU(3), TEN-TEC(4), FLEX-RADIO(5), ELCRAFT(6), BAND DATA(7), EXIT(8)

struct CATSubMenuView: View {
    @Environment(AmplifierViewModel.self) private var vm

    // Display grid (row-major) but navigate column-first
    private let gridLabels: [[String]] = [
        ["NONE", "YAESU", "ELCRAFT"],
        ["ICOM", "TEN-TEC", "BAND DATA"],
        ["KENWOOD", "FLEX-RADIO", "EXIT"],
    ]

    // Navigation order (column-first): maps nav index to (row, col)
    private let navToGrid: [(row: Int, col: Int)] = [
        (0, 0), (1, 0), (2, 0),  // NONE, ICOM, KENWOOD
        (0, 1), (1, 1), (2, 1),  // YAESU, TEN-TEC, FLEX-RADIO
        (0, 2), (1, 2), (2, 2),  // ELCRAFT, BAND DATA, EXIT
    ]

    var body: some View {
        let cursor = vm.subMenuCursorIndex
        let cursorPos = cursor < navToGrid.count ? navToGrid[cursor] : (row: -1, col: -1)

        LCDContainer(
            title: "SET CAT INTERFACE",
            subtitle: "INPUT \(vm.state.input)",
            hintLeft: "[\u{25C0}\u{25B6}]: SELECT",
            hintRight: "[SET]: CONFIRM"
        ) {
            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 2) {
                        ForEach(0..<3, id: \.self) { col in
                            LCDItem(
                                label: gridLabels[row][col],
                                isSelected: cursorPos.row == row && cursorPos.col == col
                            )
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - YAESU Model Picker (nested under CAT → YAESU)

struct YaesuModelSubMenuView: View {
    @Environment(AmplifierViewModel.self) private var vm

    // 5 + 5 + 4 layout matching the amp's display order.
    private let col1 = ["FT100", "FT757 GX2", "FT817/847", "FT840/890", "FT897"]
    private let col2 = ["FT900", "FT920", "FT990", "FT1000", "FT1000 MP1"]
    private let col3 = ["FT1000 MP2", "FT1000 MP3", "FTXXX 2007+", "FT991"]

    var body: some View {
        let cursor = vm.subMenuCursorIndex
        LCDContainer(
            title: "SET YAESU MODEL",
            subtitle: "INPUT \(vm.state.input)",
            hintLeft: "[\u{25C0}\u{25B6}]: SELECT",
            hintRight: "[SET]: CONFIRM"
        ) {
            HStack(alignment: .top, spacing: 8) {
                column(col1, indexOffset: 0, cursor: cursor)
                column(col2, indexOffset: 5, cursor: cursor)
                column(col3, indexOffset: 10, cursor: cursor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func column(_ items: [String], indexOffset: Int, cursor: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, label in
                LCDItem(label: label, isSelected: cursor == indexOffset + idx)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - TEN-TEC Model Picker (nested under CAT → TEN-TEC)

struct TenTecModelSubMenuView: View {
    @Environment(AmplifierViewModel.self) private var vm

    // 2×2 layout matching the amp's display.
    //   col 1: OMNI VII (0), ORION I/II (1)
    //   col 2: JUPITER (2), ARGONAUT V (3)
    private let col1 = ["OMNI VII", "ORION I/II"]
    private let col2 = ["JUPITER", "ARGONAUT V"]

    var body: some View {
        let cursor = vm.subMenuCursorIndex
        LCDContainer(
            title: "SET TEN-TEC MODEL",
            subtitle: "INPUT \(vm.state.input)",
            hintLeft: "[\u{25C0}\u{25B6}]: SELECT",
            hintRight: "[SET]: CONFIRM"
        ) {
            // Only 4 items — centre the grid so it doesn't look lost
            // against the wide sub-menu container.
            HStack {
                Spacer()
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(col1.enumerated()), id: \.offset) { idx, label in
                            LCDItem(label: label, isSelected: cursor == idx)
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(col2.enumerated()), id: \.offset) { idx, label in
                            LCDItem(label: label, isSelected: cursor == 2 + idx)
                        }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
        }
    }
}

// MARK: - CAT Baud Rate Picker (shared across all CAT types)

struct BaudRateSubMenuView: View {
    @Environment(AmplifierViewModel.self) private var vm

    // 4 rows × 2 columns matching the amp's physical layout.
    //   Col 1: 1200 (0), 2400 (1), 4800 (2), 9600 (3)
    //   Col 2: 19200 (4), 38400 (5), 57600 (6), 115200 (7)
    private let col1 = ["1200", "2400", "4800", "9600"]
    private let col2 = ["19200", "38400", "57600", "115200"]

    var body: some View {
        let cursor = vm.subMenuCursorIndex
        let cat = vm.rcuFrame?.baudRateCatType ?? "—"
        let model = vm.rcuFrame?.baudRateModel ?? "ALL"

        LCDContainer(
            title: "SET CAT BAUD RATE",
            subtitle: "",
            hintLeft: "[\u{25C0}\u{25B6}]: SELECT",
            hintRight: "[SET]: CONFIRM"
        ) {
            HStack(alignment: .top, spacing: 12) {
                // Left half: INPUT + CAT type + TYPE/model label
                VStack(alignment: .leading, spacing: 6) {
                    LCDKeyValue(key: "INPUT", value: vm.state.input)
                    LCDKeyValue(key: "CAT",   value: cat)
                    LCDKeyValue(key: "TYPE",  value: model)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Right half: 4×2 speed grid.
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(col1.enumerated()), id: \.offset) { idx, label in
                            LCDItem(label: label, isSelected: cursor == idx)
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(col2.enumerated()), id: \.offset) { idx, label in
                            LCDItem(label: label, isSelected: cursor == 4 + idx)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - TUN ANT → PORT Nested Sub-Menu
//
// Layout mirrors the amp's LCD: left half shows Protocol / Data bit / Stop
// bit / Parity, right half shows the 4×2 baud grid (same as CAT baud). We
// haven't decoded the cursor for this screen yet — when captures are
// available we'll wire it the same way as BaudRateSubMenuView.

struct TunAntPortSubMenuView: View {
    @Environment(AmplifierViewModel.self) private var vm

    private let col1 = ["1200", "2400", "4800", "9600"]
    private let col2 = ["19200", "38400", "57600", "115200"]

    var body: some View {
        let f = vm.rcuFrame
        let proto  = f?.tunAntPortProtocol ?? "—"
        let dataB  = f?.tunAntPortDataBit  ?? "—"
        let stopB  = f?.tunAntPortStopBit  ?? "—"
        let parity = f?.tunAntPortParity   ?? "—"
        let cursor = vm.subMenuCursorIndex

        LCDContainer(
            title: "TUN ANT PORT",
            subtitle: "",
            hintLeft: "[\u{25C0}\u{25B6}]: SELECT",
            hintRight: "[SET]: CONFIRM"
        ) {
            HStack(alignment: .top, spacing: 12) {
                // Left half: PROTOCOL / DATA BIT / STOP BIT / PARITY.
                // Cursor indices 8-11 reserved for these (decoder TBD).
                VStack(alignment: .leading, spacing: 6) {
                    // Left-side fields are display-only; cursor never lands here.
                    LCDKeyValue(key: "PROTOCOL", value: proto)
                    LCDKeyValue(key: "DATA BIT", value: dataB)
                    LCDKeyValue(key: "STOP BIT", value: stopB)
                    LCDKeyValue(key: "PARITY",   value: parity)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Right half: 4×2 baud grid. Cursor indices 0-3 (col 1),
                // 4-7 (col 2).
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(col1.enumerated()), id: \.offset) { idx, label in
                            LCDItem(label: label, isSelected: cursor == idx)
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(col2.enumerated()), id: \.offset) { idx, label in
                            LCDItem(label: label, isSelected: cursor == 4 + idx)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

}

// MARK: - MANUAL TUNE Sub-Menu (L±/C± direct control, no cursor navigation)

struct ManualTuneSubMenuView: View {
    @Environment(AmplifierViewModel.self) private var vm

    var body: some View {
        let freq = vm.rcuFrame?.manualTuneFrequency ?? "—"
        let lVal = vm.rcuFrame?.manualTuneL ?? "—"
        let cVal = vm.rcuFrame?.manualTuneC ?? "—"

        LCDContainer(
            title: "MANUAL TUNE",
            subtitle: "BANK \"\(vm.state.memBank)\"",
            hintLeft: "[TUNE]: START TUNING",
            hintRight: "[SET]: QUIT"
        ) {
            VStack(spacing: 6) {
                // Top row: band + antenna (from CSV), plus CAT frequency when
                // the amp has it.
                HStack {
                    Text("BAND: \(vm.state.band)")
                        .font(LCDStyle.font)
                        .foregroundStyle(LCDStyle.green)
                    Spacer()
                    Text("ANT: \(vm.state.txAntenna)")
                        .font(LCDStyle.font)
                        .foregroundStyle(LCDStyle.green)
                }
                HStack {
                    Text("CAT FREQ: \(freq) MHz")
                        .font(LCDStyle.fontSmall)
                        .foregroundStyle(LCDStyle.dimGreen)
                    Spacer()
                }

                Divider().background(LCDStyle.dimGreen.opacity(0.4)).padding(.vertical, 2)

                // L and C numeric readouts from the amp's LCD. Adjust via the
                // panel's L+/L- and C+/C- buttons.
                HStack(spacing: 4) {
                    Text("[\u{25C0}L]")
                        .font(LCDStyle.fontSmall)
                        .foregroundStyle(LCDStyle.dimGreen)
                    Spacer()
                    Text("L = \(lVal) µH")
                        .font(LCDStyle.fontBold)
                        .foregroundStyle(LCDStyle.green)
                    Spacer()
                    Text("[L\u{25B6}]")
                        .font(LCDStyle.fontSmall)
                        .foregroundStyle(LCDStyle.dimGreen)
                }

                HStack(spacing: 4) {
                    Text("[\u{25C0}C]")
                        .font(LCDStyle.fontSmall)
                        .foregroundStyle(LCDStyle.dimGreen)
                    Spacer()
                    Text("C = \(cVal) pF")
                        .font(LCDStyle.fontBold)
                        .foregroundStyle(LCDStyle.green)
                    Spacer()
                    Text("[C\u{25B6}]")
                        .font(LCDStyle.fontSmall)
                        .foregroundStyle(LCDStyle.dimGreen)
                }

                Divider().background(LCDStyle.dimGreen.opacity(0.4)).padding(.vertical, 2)

                // Live status — SWR and temperature from CSV status.
                HStack {
                    Text("SWR ANT: \(vm.state.aswr)")
                        .font(LCDStyle.font)
                        .foregroundStyle(LCDStyle.green)
                    Spacer()
                    Text("\(vm.state.paTemp)\u{00B0}\(vm.cachedTempUnit)")
                        .font(LCDStyle.font)
                        .foregroundStyle(LCDStyle.green)
                }

                HStack(spacing: 8) {
                    Text("IN:\(vm.state.input)")
                    Text(vm.state.band)
                    Text("ANT:\(vm.state.txAntenna)")
                    Text("SWR:\(vm.state.swr)")
                }
                .font(LCDStyle.fontSmall)
                .foregroundStyle(LCDStyle.dimGreen)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }
}

/// Simple bar indicator for L/C values. When `level` is nil we render an
/// empty track with a subtle question-mark-like half-fill so it's obvious
/// the value wasn't decoded (instead of lying about a 50% middle value).
/// `placeholderFraction` controls that fallback — manual-tune view passes
/// 0.5 for its not-yet-decoded bars; DISPLAY passes 0 so an unknown state
/// renders empty.
private struct LCDBarView: View {
    var level: Int? = nil
    var max: Int = 1
    var placeholderFraction: Double = 0.5

    var body: some View {
        GeometryReader { geo in
            let fraction: Double = {
                guard let level, max > 0 else { return placeholderFraction }
                let clamped = Swift.max(0, Swift.min(level, max))
                return Double(clamped) / Double(max)
            }()
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(LCDStyle.dimGreen.opacity(0.3))
                RoundedRectangle(cornerRadius: 2)
                    .fill(LCDStyle.green.opacity(0.6))
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 8)
    }
}

// MARK: - DISPLAY Sub-Menu (L±/C± direct control, no cursor navigation)

struct DisplaySubMenuView: View {
    @Environment(AmplifierViewModel.self) private var vm

    var body: some View {
        // Use local counters so the app's bars always move smoothly and
        // monotonically regardless of the amp's LCD encoding. See
        // AmplifierViewModel.localBacklightLevel for the rationale.
        let backlight = vm.localBacklightLevel
        let contrast = vm.localContrastLevel
        let barMax = AmplifierViewModel.displayLevelMax

        LCDContainer(
            title: "DISPLAY SETTINGS",
            hintLeft: "[INPUT]: FACTORY DEFAULTS",
            hintRight: "[SET]: QUIT"
        ) {
            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text("BACKLIGHT:")
                        .font(LCDStyle.font)
                        .foregroundStyle(LCDStyle.green)
                    Text("[\u{25C0}L]")
                        .font(LCDStyle.fontSmall)
                        .foregroundStyle(LCDStyle.dimGreen)
                    LCDBarView(level: backlight, max: barMax, placeholderFraction: 0)
                    Text("[L\u{25B6}]")
                        .font(LCDStyle.fontSmall)
                        .foregroundStyle(LCDStyle.dimGreen)
                }

                HStack(spacing: 4) {
                    Text("CONTRAST :")
                        .font(LCDStyle.font)
                        .foregroundStyle(LCDStyle.green)
                    Text("[\u{25C0}C]")
                        .font(LCDStyle.fontSmall)
                        .foregroundStyle(LCDStyle.dimGreen)
                    LCDBarView(level: contrast, max: barMax, placeholderFraction: 0)
                    Text("[C\u{25B6}]")
                        .font(LCDStyle.fontSmall)
                        .foregroundStyle(LCDStyle.dimGreen)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - BEEP Sub-Menu (toggle, SET to quit)

struct BeepSubMenuView: View {
    @Environment(AmplifierViewModel.self) private var vm

    var body: some View {
        LCDContainer(
            title: "BEEP",
            hintLeft: "Toggles On/Off",
            hintRight: "[SET]: QUIT"
        ) {
            HStack {
                Spacer()
                Text("BEEP: ON / OFF")
                    .font(LCDStyle.fontBold)
                    .foregroundStyle(LCDStyle.green)
                Spacer()
            }
            .padding(.vertical, 16)
        }
    }
}

// MARK: - START Sub-Menu (toggle, SET to quit)

struct StartSubMenuView: View {
    @Environment(AmplifierViewModel.self) private var vm

    var body: some View {
        LCDContainer(
            title: "START MODE",
            hintLeft: "Toggles Oper/Stby",
            hintRight: "[SET]: QUIT"
        ) {
            HStack {
                Spacer()
                Text("START: OPER / STBY")
                    .font(LCDStyle.fontBold)
                    .foregroundStyle(LCDStyle.green)
                Spacer()
            }
            .padding(.vertical, 16)
        }
    }
}

// MARK: - TEMP/FANS Sub-Menu
// Items: TEMP SCALE(0), FAN MGMT(1), SAVE(2)

struct TempFansSubMenuView: View {
    @Environment(AmplifierViewModel.self) private var vm

    var body: some View {
        let cursor = vm.subMenuCursorIndex
        // Live values from the amp's LCD; fall back to placeholders before
        // the first frame arrives.
        let tempScale = vm.rcuFrame?.temperatureScale ?? "—"
        let fanMgmt = vm.rcuFrame?.fanManagement ?? "—"

        LCDContainer(
            title: "TEMPERATURE AND FANS",
            hintLeft: "[\u{25C0}\u{25B6}]: SELECT",
            hintRight: "[SET]: CONFIRM"
        ) {
            VStack(spacing: 4) {
                HStack {
                    LCDItem(label: "TEMPERATURE SCALE", isSelected: cursor == 0)
                    Spacer()
                    Text(tempScale)
                        .font(LCDStyle.font)
                        .foregroundStyle(LCDStyle.green)
                }
                HStack {
                    LCDItem(label: "FAN MANAGEMENT", isSelected: cursor == 1)
                    Spacer()
                    Text(fanMgmt)
                        .font(LCDStyle.font)
                        .foregroundStyle(LCDStyle.green)
                }
                HStack {
                    Spacer()
                    LCDItem(label: "SAVE", isSelected: cursor == 2)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - TUN ANT Sub-Menu
// Items (column-first): ANT1(0), ANT2(1), ANT3(2), ANT4(3), PORT(4), SAVE(5)

struct TunAntSubMenuView: View {
    @Environment(AmplifierViewModel.self) private var vm

    var body: some View {
        let cursor = vm.subMenuCursorIndex
        let statuses = vm.rcuFrame?.tunAntStatuses ?? ["—", "—", "—", "—"]

        LCDContainer(
            title: "TUNABLE ANTENNAS",
            subtitle: "BANK \"\(vm.state.memBank)\"",
            hintLeft: "[\u{25C0}\u{25B6}]: SELECT",
            hintRight: "[SET]: CHANGE"
        ) {
            VStack(spacing: 4) {
                HStack {
                    LCDItem(label: "ANT1: \(statuses[0])", isSelected: cursor == 0)
                    Spacer()
                    LCDItem(label: "ANT3: \(statuses[2])", isSelected: cursor == 2)
                    Spacer()
                    LCDItem(label: "PORT", isSelected: cursor == 4)
                }
                HStack {
                    LCDItem(label: "ANT2: \(statuses[1])", isSelected: cursor == 1)
                    Spacer()
                    LCDItem(label: "ANT4: \(statuses[3])", isSelected: cursor == 3)
                    Spacer()
                    LCDItem(label: "SAVE", isSelected: cursor == 5)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - RX ANT Sub-Menu
// Items: ANT2(0), ANT3(1), ANT4(2), SAVE(3)

struct RxAntSubMenuView: View {
    @Environment(AmplifierViewModel.self) private var vm

    var body: some View {
        let cursor = vm.subMenuCursorIndex
        let statuses = vm.rcuFrame?.rxAntStatuses ?? ["—", "—", "—"]

        LCDContainer(
            title: "RX-ONLY ANTENNA",
            subtitle: "BANK \"\(vm.state.memBank)\"",
            hintLeft: "[\u{25C0}\u{25B6}]: SELECT",
            hintRight: "[SET]: CHANGE"
        ) {
            // Fully vertical layout matches the amp's physical menu ordering.
            VStack(alignment: .leading, spacing: 4) {
                LCDItem(label: "ANT2: \(statuses[0])", isSelected: cursor == 0)
                LCDItem(label: "ANT3: \(statuses[1])", isSelected: cursor == 1)
                LCDItem(label: "ANT4: \(statuses[2])", isSelected: cursor == 2)
                HStack {
                    Spacer()
                    LCDItem(label: "SAVE", isSelected: cursor == 3)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - ALARMS LOG Sub-Menu (scroll with arrows, SET to quit)

struct AlarmsLogSubMenuView: View {
    @Environment(AmplifierViewModel.self) private var vm

    var body: some View {
        let entries = vm.rcuFrame?.alarmLogEntries ?? []

        LCDContainer(
            title: "ALARMS LOG",
            hintLeft: "[\u{25C0}\u{25B6}]: SCROLL",
            hintRight: "[SET]: QUIT"
        ) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Scroll with [\u{25C0}\u{25B6}]. Clear history: hold TUNE+OP on amp.")
                    .font(LCDStyle.fontSmall)
                    .foregroundStyle(LCDStyle.dimGreen)
                    .padding(.bottom, 4)

                if entries.isEmpty {
                    // No frame yet, or no alarms on screen.
                    if vm.rcuFrame == nil {
                        Text("Waiting for amp data…")
                            .font(LCDStyle.font)
                            .foregroundStyle(LCDStyle.dimGreen)
                    } else {
                        Text("No alarm history")
                            .font(LCDStyle.font)
                            .foregroundStyle(LCDStyle.dimGreen)
                    }
                } else {
                    ForEach(entries, id: \.self) { entry in
                        Text(entry)
                            .font(LCDStyle.font)
                            .foregroundStyle(LCDStyle.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // Also surface any currently-active warning/alarm from CSV
                // below the history (these come from the live status stream).
                if !vm.state.warnings.isEmpty || !vm.state.error.isEmpty {
                    Divider().background(LCDStyle.dimGreen.opacity(0.4)).padding(.vertical, 4)
                    if !vm.state.warnings.isEmpty {
                        Text("ACTIVE WARNING: \(vm.state.warnings)")
                            .font(LCDStyle.fontSmall)
                            .foregroundStyle(.orange)
                    }
                    if !vm.state.error.isEmpty {
                        Text("ACTIVE ALARM: \(vm.state.error)")
                            .font(LCDStyle.fontSmall)
                            .foregroundStyle(.red)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - CAT / DISP Info Screen (read-only LCD mirror)
//
// Triggered by CAT or DISP button presses in STANDBY / OPERATE. The amp
// cycles through several screens (CAT settings, system info, serial
// number, BIAS CHECK, etc.) with further presses; each sends a fresh
// RCU frame with a different header. We render the decoded LCD rows
// verbatim — no cursor, no tap targets. Once we understand the layouts
// better we can add structured fields per screen type.

struct InfoScreenView: View {
    @Environment(AmplifierViewModel.self) private var vm

    var body: some View {
        // Title comes from the parsed header row (authoritative); body
        // segments are everything below it.
        let rawTitle = vm.infoScreenTitle.trimmingCharacters(in: .whitespaces)
        let title = rawTitle.isEmpty ? "INFO" : rawTitle
        let body = vm.infoScreenLines
        let isCatReport = title.uppercased().contains("CAT SETTING")

        LCDContainer(
            title: title,
            subtitle: "",
            hintLeft: "[CAT/DISP]: NEXT",
            hintRight: "Press again to exit"
        ) {
            if isCatReport {
                catReportLayout(body)
            } else {
                VStack(alignment: .center, spacing: 4) {
                    ForEach(Array(body.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundStyle(LCDStyle.green)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
    }

    /// CAT SETTING REPORT is split between two CAT inputs side-by-side on
    /// the amp's LCD. Segments arrive in row-major order:
    ///   [INPUT 1, INPUT 2, CAT : ..., CAT : ..., TYPE: ..., RATE: ...]
    /// The first two pairs are left/right; anything after the CAT-line
    /// pair belongs to whichever input actually has a configured radio
    /// (TYPE/RATE only make sense for a non-NONE CAT). Render as two
    /// independent columns with a vertical divider.
    /// Build per-column line arrays from the segments list. Extracted
    /// from the body so the ViewBuilder below stays pure-expression.
    private func catReportColumns(_ segments: [String]) -> (left: [String], right: [String]) {
        var leftLines: [String] = []
        var rightLines: [String] = []

        let pairCount = min(2, segments.count / 2)
        for pairIndex in 0..<pairCount {
            leftLines.append(segments[pairIndex * 2])
            rightLines.append(segments[pairIndex * 2 + 1])
        }

        // Remaining segments (TYPE/RATE/…) describe the currently-active
        // CAT input. Attach them to whichever column has a non-NONE CAT
        // entry — that's the input the radio is actually on.
        let tail = Array(segments.dropFirst(pairCount * 2))
        if !tail.isEmpty {
            let leftHasCat = leftLines.count > 1
                && !leftLines[1].uppercased().contains("NONE")
            if leftHasCat {
                leftLines.append(contentsOf: tail)
            } else {
                rightLines.append(contentsOf: tail)
            }
        }
        return (leftLines, rightLines)
    }

    @ViewBuilder
    private func catReportLayout(_ segments: [String]) -> some View {
        let cols = catReportColumns(segments)
        HStack(alignment: .top, spacing: 0) {
            column(cols.left)
            Rectangle()
                .fill(LCDStyle.dimGreen)
                .frame(width: 1)
                .padding(.vertical, 4)
            column(cols.right)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func column(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(LCDStyle.green)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Standby Banner (replaces the power meter while amp is idle)
//
// When the amp is in STANDBY, the power meter always reads 0 W — the
// panel space is more useful showing what the amp itself renders on its
// LCD: "EXPERT 1.5K FA / SOLID STATE / FULLY AUTOMATIC / STANDBY".
// Text is taken directly from the standby RCU frame so firmware/model
// variants render whatever the amp shows.

struct StandbyBannerView: View {
    @Environment(AmplifierViewModel.self) private var vm

    var body: some View {
        // Fall back to a static banner if we don't have a parsed LCD
        // mirror yet — happens right after reconnect or before the first
        // RCU standby frame arrives. Prevents the view above from
        // flipping to the power meter while the pipeline catches up.
        let lines: [String] = vm.standbyBannerLines.isEmpty
            ? ["EXPERT", "SOLID STATE", "FULLY AUTOMATIC", "STANDBY"]
            : vm.standbyBannerLines

        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                    let isLast = idx == lines.count - 1
                    Text(line)
                        .font(.system(
                            size: isLast ? 16 : 14,
                            weight: .semibold,
                            design: .monospaced))
                        .foregroundStyle(isLast ? .white : LCDStyle.green)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(LCDStyle.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(LCDStyle.dimGreen.opacity(0.5), lineWidth: 1)
        )
    }
}

// MARK: - Alert Banner (replaces main display area during alarms/warnings)
//
// When the amp reports an alarm (field 19 in CSV) or warning (field 18),
// we commandeer the main display slot with a high-contrast banner so
// the user can't miss it. Same height as StandbyBannerView / sub-menu
// LCDContainer, so nothing below shifts when the banner appears.

struct AlertBannerView: View {
    @Environment(AmplifierViewModel.self) private var vm

    var body: some View {
        let isError = !vm.state.error.isEmpty
        let message = isError ? vm.state.error : vm.state.warnings
        let accent: Color = isError ? .red : .orange

        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                Image(systemName: isError ? "exclamationmark.triangle.fill"
                                          : "exclamationmark.circle.fill")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(accent)
                Text(isError ? "ALARM" : "WARNING")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accent.opacity(0.8))
                    .tracking(2)
                Text(message)
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, 18)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(accent.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(accent.opacity(0.45), lineWidth: 1)
        )
    }
}

// MARK: - Amp-Powered-Off Banner
//
// Replaces the main display area when CSV updates have stalled for
// more than ~4 seconds while the WebSocket connection is still up.
// Indicates the amp is powered off (FTDI USB stays connected, only
// the amp's serial output stops). Same footprint as other banners.

struct AmpOffBannerView: View {
    @Environment(AmplifierViewModel.self) private var vm

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                Image(systemName: "powersleep")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(Color(white: 0.45))
                Text("AMP")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(white: 0.55))
                    .tracking(2)
                Text("POWERED OFF")
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                Text(vm.isConnected
                     ? "Press POWER ON to wake the amplifier"
                     : "Connection lost")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(white: 0.5))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(white: 0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(white: 0.25), lineWidth: 1)
        )
    }
}
