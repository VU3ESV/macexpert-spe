import Foundation

/// Presence heartbeat emitted by spe-remote every ~5 s. `serial` reports
/// amp liveness independent of the WebSocket connection — the FTDI USB
/// link to the Pi stays alive even when the amp's CPU is powered off,
/// so the gateway distinguishes "WS up, amp talking" (`up`) from
/// "WS up, amp silent" (`down`) and tells us explicitly.
///
/// Wire format (per spe-remote/spe/websocket_handler.py):
/// ```
/// { "heartbeat": true, "serial": "up"|"down", "ts": 1778607559.5, "clients": 3 }
/// ```
struct PresenceHeartbeat: Decodable {
    let heartbeat: Bool
    let serial: String
    let ts: Double
    let clients: Int

    var ampAlive: Bool { serial == "up" }
}

/// WebSocket connection to the spe-remote server.
@MainActor
final class WebSocketConnection: NSObject, ConnectionProvider, @unchecked Sendable {
    var isConnected: Bool = false
    var onStateUpdate: ((AmplifierState) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    /// Fired when spe-remote forwards a 0x6A RCU LCD display frame as a
    /// binary WebSocket message. Payload matches what the serial path
    /// delivers — bytes after the `AA AA AA 6A` sync+marker — so the same
    /// RCUFrame parser works on both transports.
    var onRCUDisplayPacket: ((Data) -> Void)?
    /// Not currently emitted — raw byte stream isn't exposed by spe-remote.
    var onRawBytes: ((Data) -> Void)?
    /// Fired each time an RCU frame arrives. Lets the debug overlay count
    /// frames even though we aren't driving the OFF→ON ticker locally (the
    /// Pi server does that on our behalf).
    var onRCUTick: (() -> Void)?
    /// Fired on every spe-remote presence heartbeat (~5 s cadence). Use
    /// `heartbeat.ampAlive` to drive the amp-off banner directly instead
    /// of waiting on the silence watchdog.
    var onHeartbeat: ((PresenceHeartbeat) -> Void)?
    /// Fired on every tune-orchestrator phase transition from the Pi —
    /// SWEEP_STARTED / SWEEP_STEP / LED_ON / … / SWEEP_DONE / FAIL / ABORT.
    /// Used by the Sweep panel to drive its progress display and Stop
    /// button state. The Pi broadcasts these as JSON keyed on
    /// `tune_event`; see Models/TuneEvent.swift for the shape.
    var onTuneEvent: ((TuneEvent) -> Void)?
    /// Fired when spe-remote sends a radio-config snapshot
    /// (`config_event:"radio"`) — in reply to `get_config` or after a
    /// `set_radio_config`. Drives the radio-settings picker.
    var onRadioConfig: ((RadioConfig) -> Void)?

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var url: URL
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var shouldReconnect = false
    private var reconnectDelay: TimeInterval = 1.0
    private let maxReconnectDelay: TimeInterval = 16.0

    init(url: URL) {
        self.url = url
        super.init()
    }

    func configure(url: URL) {
        self.url = url
    }

    func connect() async throws {
        shouldReconnect = true
        reconnectDelay = 1.0

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)

        guard let ws = session?.webSocketTask(with: url) else {
            throw ConnectionError.websocketFailed("Failed to create WebSocket task")
        }

        webSocketTask = ws
        ws.resume()

        isConnected = true
        onConnectionChange?(true)
        reconnectDelay = 1.0

        startReceiving()
    }

    func disconnect() {
        shouldReconnect = false
        receiveTask?.cancel()
        receiveTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        isConnected = false
        onConnectionChange?(false)
    }

    func sendCommand(_ command: SPECommand) {
        guard let ws = webSocketTask else { return }

        let message: String
        switch command {
        case .status:
            // In WebSocket mode, server pushes state — no explicit status request needed
            return
        default:
            message = command.wsCommandName
        }

        ws.send(.string(message)) { error in
            if let error {
                print("WebSocket send error: \(error.localizedDescription)")
            }
        }
    }

    func powerOn() async {
        sendRawCommand("power_on")
    }

    /// Send a raw string command (for power_on which isn't in SPECommand).
    func sendRawCommand(_ command: String) {
        guard let ws = webSocketTask else { return }
        ws.send(.string(command)) { error in
            if let error {
                print("WebSocket send error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Receive Loop

    private func startReceiving() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop()
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let ws = webSocketTask else { break }

            do {
                let message = try await ws.receive()
                await handleMessage(message)
            } catch {
                await handleDisconnect()
                break
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) async {
        switch message {
        case .string(let text):
            guard let data = text.data(using: .utf8) else { return }
            // spe-remote multiplexes several JSON message types on the
            // same socket. Discriminate by root keys (see handover doc
            // 2026-05-12): heartbeat → presence; op_status → state
            // snapshot; power_result → command ack. Anything else is
            // dropped silently — the gateway is forward-compatible.
            let decoder = JSONDecoder()
            if let hb = try? decoder.decode(PresenceHeartbeat.self, from: data),
               hb.heartbeat {
                await MainActor.run { onHeartbeat?(hb) }
                return
            }
            // tune_event must come BEFORE state — TuneEvent.phase has its
            // own coding key `tune_event`, so a successful TuneEvent
            // decode signals a phase transition (not a partial state).
            // State decode would otherwise accept the same JSON with
            // most fields defaulted, which is exactly the regression
            // d3be36f closed for power_result messages.
            if let ev = try? decoder.decode(TuneEvent.self, from: data) {
                await MainActor.run { onTuneEvent?(ev) }
                return
            }
            // Radio-config snapshot — decode BEFORE state for the same
            // reason as tune_event: it carries its own discriminator
            // (`config_event`) and would otherwise be swallowed by the
            // permissive AmplifierState decode.
            if let cfg = try? decoder.decode(RadioConfigMessage.self, from: data),
               cfg.configEvent == "radio" {
                await MainActor.run { onRadioConfig?(cfg.radio) }
                return
            }
            if let state = try? decoder.decode(AmplifierState.self, from: data) {
                await MainActor.run { onStateUpdate?(state) }
                return
            }
            // power_result / unknown — no UI surface yet.
        case .data(let data):
            // spe-remote sends RCU LCD frames as binary messages (the bytes
            // after AA AA AA 6A). Anything else binary-shaped is unexpected
            // but treat the same way — RCUFrame.parse will bail gracefully
            // if the payload doesn't look right.
            await MainActor.run {
                onRCUDisplayPacket?(data)
                onRCUTick?()
            }
        @unknown default:
            break
        }
    }

    private func handleDisconnect() async {
        await MainActor.run {
            isConnected = false
            onConnectionChange?(false)
        }

        guard shouldReconnect else { return }

        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(reconnectDelay))

            guard !Task.isCancelled, shouldReconnect else { return }

            await MainActor.run {
                reconnectDelay = min(reconnectDelay * 2, maxReconnectDelay)
            }

            do {
                try await connect()
            } catch {
                print("Reconnect failed: \(error.localizedDescription)")
            }
        }
    }
}
