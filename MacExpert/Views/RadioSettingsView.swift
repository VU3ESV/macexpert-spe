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

    /// What's in the fields (strings as typed; validated and converted by
    /// `RadioForm`).
    @State private var form = RadioForm()
    /// The form as last filled from the Pi's config. Nil until a config has
    /// arrived, so Apply can't send the placeholder defaults. `form != loaded`
    /// means the operator has edits.
    @State private var loaded: RadioForm?
    /// A config broadcast (e.g. another client's change) that arrived while
    /// the operator had edits. Offered via Reload instead of overwriting.
    @State private var pending: RadioConfig?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Picker("Radio", selection: $form.kind) {
                Text("None").tag("none")
                Text("FlexRadio (SmartSDR)").tag("flex")
                Text("SunSDR / ExpertSDR3 (TCI)").tag("tci")
            }
            .pickerStyle(.segmented)

            if form.kind == "flex" {
                fieldGroup {
                    field("Host", $form.flexHost, placeholder: "empty = auto-discover")
                    field("Port", $form.flexPort)
                    field("Slice", $form.flexSlice)
                    field("Tune W", $form.flexPower)
                }
            } else if form.kind == "tci" {
                fieldGroup {
                    field("Host", $form.tciHost, placeholder: "127.0.0.1")
                    field("Port", $form.tciPort)
                    field("TRX", $form.tciTrx)
                    field("Mode", $form.tciMode)
                    field("Tune %", $form.tciDrive)
                }
            } else {
                Text("No tune radio — the SWEEP / orchestrated TUNE features are disabled.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            notices
            controls
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 280)
        .onAppear {
            vm.refreshRadioConfig()
            if let cfg = vm.radioConfig { adopt(cfg) }
        }
        .onChange(of: vm.radioConfig) { _, cfg in
            guard let cfg else { return }
            // No edits yet: show the Pi's config. Edits: keep them, offer Reload.
            if loaded == nil || form == loaded { adopt(cfg) } else { pending = cfg }
        }
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

    /// Input problems, a config that changed underneath the edits, the
    /// "not saved" state, and waiting for the first config.
    @ViewBuilder
    private var notices: some View {
        let problems = form.problems
        if !problems.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(problems, id: \.self) { p in
                    Label(p, systemImage: "exclamationmark.circle")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.red)
        }
        if pending != nil {
            HStack(spacing: 8) {
                Label("The radio settings changed on the Pi (another client?). Reload to see them; your edits are discarded.",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Reload") { if let cfg = pending { adopt(cfg) } }
                    .controlSize(.small)
            }
        }
        if vm.radioChangeNotSaved {
            Label("The last radio change is live but the Pi couldn't save it to config.yaml, so it reverts when spe-remote restarts.",
                  systemImage: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if loaded == nil && vm.isConnected && vm.connectionMode == .websocket {
            Label("Waiting for the Pi's current settings…", systemImage: "hourglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
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
                guard let payload = form.payload() else { return }
                vm.setRadioConfig(payload)
                dismiss()
            } label: {
                Label("Apply", systemImage: "checkmark")
                    .frame(minWidth: 90, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            // Not before the Pi's config has arrived (Apply would otherwise
            // send the placeholder defaults, e.g. kind "none"), nor with
            // invalid input.
            .disabled(vm.isSweeping || !vm.isConnected || vm.connectionMode != .websocket
                      || loaded == nil || !form.problems.isEmpty)
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

    // MARK: - Sync

    /// Fill the form from the Pi's config and treat that as the clean state.
    private func adopt(_ cfg: RadioConfig) {
        let filled = RadioForm(cfg, over: loaded ?? RadioForm())
        form = filled
        loaded = filled
        pending = nil
    }
}
