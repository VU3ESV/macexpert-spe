import SwiftUI

/// Lets the operator pick which rig drives the orchestrated TUNE / band
/// sweep — a FlexRadio (SmartSDR) or a SunSDR (TCI) — and edit its
/// connection settings. The choice applies live on the Pi and persists to
/// its config.yaml (see spe-remote `docs/CLIENT_RADIO_CONFIG.md`); no
/// restart. Reads the current config from `vm.radioConfig` and writes
/// changes via `vm.setRadioConfig`.
///
/// WebSocket mode only — the sweep itself depends on the Pi's rig client.
struct RadioSettingsView: View {
    @Environment(AmplifierViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    // Form state (strings so the text fields stay simple; converted on Apply).
    @State private var kind = "none"
    @State private var flexHost = ""
    @State private var flexPort = "4992"
    @State private var flexSlice = "0"
    @State private var flexPower = "10"
    @State private var tciHost = "127.0.0.1"
    @State private var tciPort = "50001"
    @State private var tciTrx = "0"
    @State private var tciMode = "CW"
    @State private var tciDrive = "0"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Picker("Radio", selection: $kind) {
                Text("None").tag("none")
                Text("FlexRadio (SmartSDR)").tag("flex")
                Text("SunSDR / ExpertSDR3 (TCI)").tag("tci")
            }
            .pickerStyle(.segmented)

            if kind == "flex" {
                fieldGroup {
                    field("Host", $flexHost, placeholder: "empty = auto-discover")
                    field("Port", $flexPort)
                    field("Slice", $flexSlice)
                    field("Tune W", $flexPower)
                }
            } else if kind == "tci" {
                fieldGroup {
                    field("Host", $tciHost, placeholder: "127.0.0.1")
                    field("Port", $tciPort)
                    field("TRX", $tciTrx)
                    field("Mode", $tciMode)
                    field("Tune %", $tciDrive)
                }
            } else {
                Text("No tune radio — the SWEEP / orchestrated TUNE features are disabled.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            controls
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 280)
        .onAppear {
            vm.refreshRadioConfig()
            sync(from: vm.radioConfig)
        }
        .onChange(of: vm.radioConfig) { _, cfg in sync(from: cfg) }
    }

    // MARK: - Sub-views

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Radio for TUNE / Sweep")
                    .font(.system(size: 16, weight: .semibold))
                Text("Switching applies immediately on the Pi — no restart. Refused while a tune is running.")
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

    private var controls: some View {
        HStack {
            if vm.isSweeping {
                Label("Tune in progress — can't switch", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button {
                vm.setRadioConfig(payload())
                dismiss()
            } label: {
                Label("Apply", systemImage: "checkmark")
                    .frame(minWidth: 90, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(vm.isSweeping || !vm.isConnected || vm.connectionMode != .websocket)
        }
    }

    private func fieldGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) { content() }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    private func field(_ label: String, _ text: Binding<String>,
                       placeholder: String = "") -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    // MARK: - Sync / build

    private func sync(from cfg: RadioConfig?) {
        guard let cfg else { return }
        kind = cfg.kind
        if let f = cfg.flex {
            if let v = f.host { flexHost = v }
            if let v = f.port { flexPort = String(v) }
            if let v = f.slice_rx { flexSlice = String(v) }
            if let v = f.tune_power_watts { flexPower = String(v) }
        }
        if let t = cfg.tci {
            if let v = t.host { tciHost = v }
            if let v = t.port { tciPort = String(v) }
            if let v = t.trx { tciTrx = String(v) }
            if let v = t.mode { tciMode = v }
            if let v = t.tune_drive { tciDrive = String(v) }
        }
    }

    private func payload() -> [String: Any] {
        var p: [String: Any] = ["kind": kind]
        if kind == "flex" {
            p["flex"] = [
                "host": flexHost,
                "port": Int(flexPort) ?? 4992,
                "slice_rx": Int(flexSlice) ?? 0,
                "tune_power_watts": Int(flexPower) ?? 10,
            ]
        } else if kind == "tci" {
            p["tci"] = [
                "host": tciHost,
                "port": Int(tciPort) ?? 50001,
                "trx": Int(tciTrx) ?? 0,
                "mode": tciMode.isEmpty ? "CW" : tciMode,
                "tune_drive": Int(tciDrive) ?? 0,
            ]
        }
        return p
    }
}
