import SwiftUI

struct ConnectionView: View {
    @Environment(AmplifierViewModel.self) private var vm
    @State private var isExpanded = true

    var body: some View {
        @Bindable var vm = vm

        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: "cable.connector")
                        .foregroundStyle(.cyan)
                    Text("Connection")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 10) {
                    Picker("Mode", selection: $vm.connectionMode) {
                        ForEach(ConnectionMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(vm.isConnected)

                    if vm.connectionMode == .serial {
                        serialSettings
                    } else {
                        websocketSettings
                    }

                    Toggle("Reconnect on launch", isOn: $vm.autoReconnectOnLaunch)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    HStack {
                        if !vm.errorMessage.isEmpty {
                            Text(vm.errorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button(vm.isConnected ? "Disconnect" : "Connect") {
                            if vm.isConnected { vm.disconnect() } else { vm.connect() }
                        }
                        .controlSize(.regular)
                        .buttonStyle(.borderedProminent)
                        .tint(vm.isConnected ? .red.opacity(0.8) : .cyan)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.15)))
        .onChange(of: vm.isConnected) { _, connected in
            if connected {
                withAnimation(.easeInOut(duration: 0.3)) { isExpanded = false }
            } else if !vm.errorMessage.isEmpty {
                // e.g. the proxy refused the login: the panel collapsed when
                // the socket opened, so re-open it to show why it closed.
                withAnimation(.easeInOut(duration: 0.3)) { isExpanded = true }
            }
        }
        .onChange(of: vm.errorMessage) { _, message in
            if !message.isEmpty && !vm.isConnected {
                withAnimation(.easeInOut(duration: 0.3)) { isExpanded = true }
            }
        }
    }

    @ViewBuilder
    private var serialSettings: some View {
        HStack {
            Text("Port").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
            Picker("", selection: Bindable(vm).selectedPortPath) {
                if vm.availablePorts.isEmpty { Text("No ports available").tag("") }
                ForEach(vm.availablePorts, id: \.path) { port in Text(port.name).tag(port.path) }
            }.labelsHidden().disabled(vm.isConnected)
            Button { vm.refreshPorts() } label: { Image(systemName: "arrow.clockwise") }.disabled(vm.isConnected)
        }
        HStack {
            Text("Baud").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
            Picker("", selection: Bindable(vm).baudRate) {
                Text("115200").tag(115200); Text("57600").tag(57600)
                Text("38400").tag(38400); Text("9600").tag(9600)
            }.labelsHidden().disabled(vm.isConnected).frame(maxWidth: 120)
            Spacer()
        }
    }

    @ViewBuilder
    private var websocketSettings: some View {
        HStack {
            Text("Host").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
            TextField("IP or hostname", text: Bindable(vm).wsHost).textFieldStyle(.roundedBorder).disabled(vm.isConnected)
            Text(":").foregroundStyle(.secondary)
            TextField("Port", value: Bindable(vm).wsPort, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 65).disabled(vm.isConnected)
        }
        HStack {
            Toggle("Use TLS (wss)", isOn: Bindable(vm).wsUseTLS)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.system(size: 11))
                .disabled(vm.isConnected)
                .help("Connect with wss:// — for spe-remote behind the authenticating TLS proxy. The proxy login is only ever sent over TLS.")
            Spacer()
        }
        if vm.wsUseTLS {
            ProxyLoginSection()
        }
    }
}

/// Proxy login for the authenticating TLS proxy: a generic-password item
/// in the Keychain (service "ShackProxy", account = username). The stored
/// password is never read back into this view — the field only ever holds
/// what the operator is typing to save.
private struct ProxyLoginSection: View {
    @Environment(AmplifierViewModel.self) private var vm
    @State private var username = "operator"
    @State private var password = ""
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Proxy login")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                statusLabel
            }
            HStack {
                Text("User").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                TextField("operator", text: $username)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Pass").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                SecureField(isStored ? "Stored — type to replace" : "Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
            }
            HStack(spacing: 8) {
                if !vm.proxyLoginMessage.isEmpty {
                    Text(vm.proxyLoginMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Remove", role: .destructive) {
                    isBusy = true
                    Task {
                        await vm.removeProxyLogin()
                        isBusy = false
                    }
                }
                .controlSize(.small)
                .disabled(isBusy || !isStored)
                Button("Save to Keychain", action: save)
                    .controlSize(.small)
                    .disabled(isBusy || password.isEmpty
                              || username.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        .task {
            // Attributes only — no decrypt, so no Keychain prompt here.
            if let stored = await vm.refreshProxyLoginStatus(), !stored.isEmpty {
                username = stored
            }
        }
    }

    private var isStored: Bool {
        if case .stored = vm.proxyLoginStatus { return true }
        return false
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch vm.proxyLoginStatus {
        case .stored(let user):
            Label("Stored (\(user))", systemImage: "key.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .notStored:
            Label("Not stored", systemImage: "key.slash")
                .font(.caption)
                .foregroundStyle(.orange)
        case .unknown:
            Text("—").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func save() {
        guard !password.isEmpty else { return }
        isBusy = true
        let user = username
        let pass = password
        Task {
            await vm.saveProxyLogin(username: user, password: pass)
            password = ""
            isBusy = false
        }
    }
}
