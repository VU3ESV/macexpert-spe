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
    }
}
