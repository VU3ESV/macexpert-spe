import SwiftUI

/// Modal sheet for the ATU band sweep — Phase 2c of the band-sweep
/// work. Operator picks a band, hits Start, watches progress, can Stop
/// mid-stream. Lives behind a "SWEEP" button in ControlsView; the
/// existing TUNE button is left alone (just sends the SPE keycode, no
/// Flex coordination).
///
/// Reads its state off `vm.lastTuneEvent` / `vm.isSweeping` /
/// `vm.sweepProgress`, which the ViewModel updates from the Pi's
/// tune_event broadcasts in real time.
struct SweepPanelView: View {
    @Environment(AmplifierViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    /// Band keys in wavelength order — matches the SPE's own band
    /// labels. Operator picks before starting; we don't auto-detect
    /// from the amp because the operator (per the SPE manual) is
    /// expected to have already set the band + antenna by hand.
    private static let bands = [
        "160m", "80m", "60m", "40m", "30m", "20m",
        "17m", "15m", "12m", "10m", "6m",
    ]

    @State private var selectedBand: String = "20m"
    @State private var showStartConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            bandPicker
            statusBlock
            controls
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 320)
        // On-demand radio lifecycle: opening this panel pre-warms the Pi's
        // rig connection (Flex or SunSDR); closing it (while idle) drops it
        // again. The Pi also connects lazily at tune start and disconnects
        // when the cycle is over, so this is purely a head-start.
        .onAppear { vm.radioConnect() }
        .onDisappear { vm.radioDisconnect() }
    }

    // MARK: - Sub-views

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("ATU Band Sweep")
                    .font(.system(size: 16, weight: .semibold))
                Text("Visits each in-band sub-band freq from the SPE manual; the amp learns SWR for that band.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Close")
        }
    }

    private var bandPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("BAND")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(1)
            // Use a 6-wide grid so the 11 bands wrap to two rows.
            // Single-line picker would be too cramped on the narrower
            // sheet widths.
            let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Self.bands, id: \.self) { band in
                    Button {
                        selectedBand = band
                    } label: {
                        Text(band)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .buttonStyle(.bordered)
                    .tint(selectedBand == band ? .accentColor : .secondary)
                    .disabled(vm.isSweeping)
                }
            }
        }
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("STATUS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    statusIcon
                    Text(statusHeadline)
                        .font(.system(size: 13, weight: .semibold))
                }
                if let progress = vm.sweepProgress {
                    progressBar(progress)
                }
                if let event = vm.lastTuneEvent, !event.message.isEmpty {
                    Text(event.message)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.08))
            )
        }
    }

    private func progressBar(_ progress: (current: Int, total: Int)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(progress.current) / \(progress.total) sub-bands")
                    .font(.system(size: 10, design: .monospaced))
                Spacer()
                let pct = progress.total > 0
                    ? Int(Double(progress.current) / Double(progress.total) * 100)
                    : 0
                Text("\(pct)%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(progress.current),
                         total: Double(max(progress.total, 1)))
                .progressViewStyle(.linear)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        let phase = vm.lastTuneEvent?.phase ?? ""
        switch phase {
        case "SUCCESS", "SWEEP_DONE":
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case "FAIL":
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case "ABORT":
            Image(systemName: "stop.circle.fill").foregroundStyle(.orange)
        case "":
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        default:
            // Running phase — animated indicator
            ProgressView().controlSize(.small)
        }
    }

    private var statusHeadline: String {
        guard let event = vm.lastTuneEvent else {
            return vm.isSweeping ? "Starting…" : "Ready"
        }
        switch event.phase {
        case "SWEEP_DONE": return "Done"
        case "SUCCESS":    return "Cycle complete"
        case "FAIL":       return "Failed"
        case "ABORT":      return "Stopped"
        default:           return event.phase.replacingOccurrences(of: "_", with: " ")
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                showStartConfirm = true
            } label: {
                Label("Start Sweep on \(selectedBand)",
                      systemImage: "play.fill")
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(vm.isSweeping || !canStart)
            .confirmationDialog(
                "Sweep \(selectedBand)?",
                isPresented: $showStartConfirm,
                titleVisibility: .visible
            ) {
                Button("Start \(selectedBand) sweep") {
                    vm.startSweep(band: selectedBand)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The amp must be in STBY and the antenna for \(selectedBand) selected before starting. The sweep will transmit briefly at each in-band sub-band freq.")
            }

            Button {
                vm.stopSweep()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .frame(minWidth: 90, minHeight: 32)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(!vm.isSweeping)
        }
    }

    /// Sweep requires WS-mode connection. We can't run the band sweep
    /// over a direct serial link — it depends on the Pi's Flex client.
    private var canStart: Bool {
        vm.isConnected && vm.connectionMode == .websocket
    }
}
