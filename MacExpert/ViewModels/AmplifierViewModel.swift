import SwiftUI
import ORSSerial

@Observable
@MainActor
final class AmplifierViewModel {
    // MARK: - Published State
    var state = AmplifierState()
    var isConnected = false
    var connectionMode: ConnectionMode = .serial {
        didSet { UserDefaults.standard.set(connectionMode.rawValue, forKey: "connectionMode") }
    }

    /// True when the user wants the app to automatically reconnect to
    /// the last successful server on launch. Persisted across launches.
    /// Default: true — the daily case is "Pi server is always running,
    /// I open MacExpert and it Just Works." Disable from the Connection
    /// view if you want manual control.
    var autoReconnectOnLaunch: Bool = true {
        didSet { UserDefaults.standard.set(autoReconnectOnLaunch, forKey: "autoReconnectOnLaunch") }
    }
    var detectedModel: AmplifierModel = .unknown
    var statusMessage: String = ""
    var errorMessage: String = ""
    var antennaMap = AntennaMap()

    // RCU capture pipeline (labeled 0x6A LCD packet logger).
    // `var` (not `let`) so SwiftUI's @Bindable projection can drill into its
    // observable properties (e.g. $vm.captureLogger.currentLabel).
    var captureLogger = CaptureLogger()
    var captureErrorMessage: String = ""

    // Most recently parsed RCU display frame. Drives live cursor tracking,
    // CONFIG checkbox state, etc.
    var rcuFrame: RCUFrame?

    /// Per-band antenna slot-1/slot-2 assignments learned from the ANTENNA
    /// matrix screen. Keyed as `"A/160M"`, `"B/20M"`, etc. (bank letter +
    /// band). Each value is `AntennaSlots` carrying both slot values.
    /// Populated live as the user walks the cursor through bands — each
    /// RCU frame on the antenna screen contributes up to 11 entries.
    /// Persists across exits of the antenna menu.
    var antennaMatrix: [String: AntennaSlots] = [:]

    /// Last-known CAT manufacturer selected for the current input. Learned
    /// by visiting the CAT sub-menu (cursor lands on the active one) or
    /// the CAT baud rate screen (which prints the manufacturer directly).
    /// Displayed as a status chip so the user can see the active CAT at a
    /// glance without navigating into SETUP.
    var cachedCatType: String = ""

    /// Last-known temperature unit reported by the amp on its TEMP/FANS
    /// screen. Persists across launches so the gauge picks the right
    /// unit even before the user has visited that menu in this session.
    /// Values: "C" (default) or "F".
    var cachedTempUnit: String = UserDefaults.standard.string(forKey: "cachedTempUnit") ?? "C" {
        didSet { UserDefaults.standard.set(cachedTempUnit, forKey: "cachedTempUnit") }
    }

    /// Item names shown in the CAT sub-menu, in cursor nav order. Used to
    /// map the cursor index on a `.catMenu` frame to the highlighted name.
    private static let catMenuItems = [
        "NONE", "ICOM", "KENWOOD", "YAESU", "TEN-TEC",
        "FLEX", "ELECRAFT", "BAND DATA", "EXIT",
    ]

    /// True while the amp is showing a CAT / DISP info screen (brought up
    /// by repeated CAT / DISP presses). Those screens have no cursor and
    /// no editable fields — we just show the amp's LCD contents verbatim.
    /// Cleared automatically when the next non-info frame arrives.
    var isShowingInfoScreen: Bool = false

    /// Decoded body segments from the most recent info-screen frame.
    /// Each segment is a clean word-group (e.g. "INPUT 1", "CAT : FLEX
    /// RADIO"). Populated by the info-screen handler in `handleRCUFrame`.
    var infoScreenLines: [String] = []

    /// Title extracted from the info-screen frame's header row. The amp's
    /// header can run up to 48 chars (e.g. "CAT SETTING REPORT INPUT"),
    /// so we surface it separately rather than guessing from body text.
    var infoScreenTitle: String = ""

    /// Timestamp of the most recent CSV state update from the amp.
    var lastStateUpdateAt: Date?

    /// Timestamp of the LAST piece of traffic we received from the amp
    /// — either a CSV state update OR an RCU display frame. RCU frames
    /// tick at ~1.5 s on a static screen, so this is a much tighter
    /// liveness signal than CSV alone (the Pi suppresses identical CSV
    /// JSON for up to 15 s as a bandwidth optimisation).
    private var lastTrafficAt: Date?

    /// True when ANY traffic from the amp has arrived recently. Goes
    /// false when the connection is up but the amp itself is silent —
    /// usually because the amp is powered off (the FTDI stays
    /// USB-connected so the WS stays up; only the amp's serial output
    /// stops).
    var isAmpResponding: Bool = false
    private var ampWatchdogTask: Task<Void, Never>?

    /// Banner lines derived from the amp's own LCD body when it's sitting
    /// in STANDBY. The amp renders "EXPERT 1.5K FA / SOLID STATE / FULLY
    /// AUTOMATIC / STANDBY" as its standby panel; we mirror that as a
    /// banner in place of the power meter for a cleaner idle look.
    /// Empty when no standby frame has been seen yet or we're not in
    /// standby.
    var standbyBannerLines: [String] = []

    /// True when the amp is sitting in STANDBY but the rig is keyed.
    /// In this state the amp is bypassed (RF passes through without
    /// amplification), so the meter sees only the exciter's drive
    /// level — typically 25–100 W. We use this to swap the standby
    /// banner out for the live power meter and force a 200 W scale.
    var isStandbyTX: Bool {
        state.opStatus == "Stby" && state.txStatus == "TX"
    }

    /// Full-scale watts for the power meter / bar. 200 W when the amp
    /// is bypassed (`isStandbyTX`), otherwise the model's per-level
    /// maximum (e.g. 500 / 1000 / 1500 on a 1.5K-FA at L/M/H).
    var powerScaleWatts: Int {
        if isStandbyTX { return 200 }
        return detectedModel.maxPowerForLevel(state.pLevel)
    }

    /// Timestamp of the last info-screen frame. Used by an auto-clear
    /// watchdog so the overlay closes when the amp transitions back to
    /// standby/operate (which can arrive as a missed/classified-away
    /// frame rather than a clean opStandby).
    private var lastInfoFrameAt: Date?
    private var infoScreenAutoClearTask: Task<Void, Never>?

    /// Current BEEP state — tracked locally. Amp doesn't expose this in
    /// CSV; we flip on each SET press while cursor is on BEEP. Nil until
    /// the user has toggled it at least once in this session.
    var beepOn: Bool? = nil

    /// Current START mode — true == OPER, false == STBY. Same tracking
    /// story as `beepOn`.
    var startInOperate: Bool? = nil

    /// The currently-active antenna's display string, e.g. "2" or "2t" or
    /// "3b". Looks up the current bank+band in `antennaMatrix`, matches the
    /// antenna number against slot 1 / slot 2, and appends the suffix
    /// (b/t/r) if one is set. Falls back to the bare number when we don't
    /// have matrix data for this band yet.
    var txAntennaWithSuffix: String {
        let num = state.txAntenna
        guard !num.isEmpty, num != "0" else { return num }
        let band = state.band.uppercased()
        // Prefer the current bank's entry, but fall back to any bank that
        // has this band mapped — the amp can be mid-transition where
        // memBank isn't populated yet, and the suffix is the same per-band
        // regardless of bank in practice.
        let bank = state.memBank
        let candidateKeys: [String] = {
            var keys: [String] = []
            if !bank.isEmpty { keys.append("\(bank)/\(band)") }
            keys.append(contentsOf: antennaMatrix.keys.filter { $0.hasSuffix("/\(band)") })
            return keys
        }()
        for key in candidateKeys {
            guard let slots = antennaMatrix[key] else { continue }
            for slot in [slots.slot1, slots.slot2] where slot.hasPrefix(num) {
                return slot
            }
        }
        return num
    }

    // MARK: - Local DISPLAY state
    //
    // The amp's LCD encodes backlight and contrast in an ambiguous way
    // (different cap glyphs on each cell, direction can appear inverted,
    // and there are "dead zones" at mid-range). Rather than fight the
    // decoder, we track our own counter. Each L+/L-/C+/C- press in the
    // DISPLAY screen moves the counter and sends the matching command
    // to the amp, so a user driving everything from the app sees smooth
    // 0..16 motion through the full 17-level range.
    //
    // Trade-off: if the user also presses physical L/C buttons on the amp
    // panel, our counter drifts from the amp's true state until the next
    // app-driven change. Acceptable per UX design.
    var localBacklightLevel: Int = 8  // Midpoint; first use starts here.
    var localContrastLevel: Int = 8

    static let displayLevelMin = 0
    static let displayLevelMax = 16

    /// Total RCU frames the parser has accepted since connect. Debug counter.
    var rcuFrameCount: Int = 0
    /// Total RCU frames received at the connection callback (before parse).
    /// If this climbs but rcuFrameCount doesn't, parse is rejecting frames.
    var rcuCallbackCount: Int = 0
    /// Most recent RCU callback timestamp — "ages" to show freshness.
    var rcuLastCallbackAt: Date?
    /// Number of RCU OFF→ON ticker cycles sent. If this climbs but
    /// `rcuCallbackCount` doesn't, the amp isn't responding to our cycles.
    var rcuTicksSent: Int = 0

    /// Who "owns" the RCU stream right now. Both the Capture pane and SETUP
    /// mode want to hold RCU on; whichever turned it on is responsible for
    /// turning it off, so the other flow doesn't get stranded.
    enum RCUOwner: String { case none, capture, setupMode }
    var rcuOwner: RCUOwner = .none

    /// Timestamp of most recent entry into SETUP mode. Used to suppress
    /// auto-exit on the first few frames (the amp can briefly flash a
    /// stale OP frame while processing the SET that entered SETUP).
    private var setupEnteredAt: Date?

    /// True while the amp is (believed to be) actively running an ATU tune.
    /// Drives the TUNE LED indicator. Currently set only on app-initiated
    /// TUNE presses and auto-cleared after the tune timeout; physical
    /// TUNE-button presses on the amp aren't detected yet — we need a
    /// reliable amp-side signal for that.
    var isTuningInProgress: Bool = false
    private var tuneTimeoutTask: Task<Void, Never>?

    /// How long to keep the TUNE LED lit after an app-initiated tune press.
    /// Matches the amp's own tune-timeout (roughly).
    private let tuneTimeoutDuration: TimeInterval = 5

    /// Timestamp of the most recent cursor-navigation command we sent to
    /// the amp (◀ / ▶). Used to suppress RCU-driven cursor overwrites for
    /// a short window after the press — otherwise a stale RCU frame that
    /// hasn't seen our command yet will bounce the cursor back to the old
    /// position, feeling laggy on fast double-taps.
    private var lastNavCommandAt: Date?
    /// How long to ignore RCU cursor updates after we send a nav command.
    /// Needs to be long enough to cover (serial RTT) + (amp processing) +
    /// (ticker interval); 600 ms covers the 400 ms tick with headroom.
    private let navSuppressionWindow: TimeInterval = 0.6

    // MARK: - Setup Mode
    var isInSetupMode = false
    var setupCursorIndex = 0
    var activeSubMenu: SetupSubMenu? = nil
    var subMenuCursorIndex = 0

    enum SetupSubMenu: String, CaseIterable {
        case config, antenna, cat, manualTune
        case display, beep, start, tempFans
        case alarmsLog, tunAnt, rxAnt
        case yaesuModel            // Nested: CAT → YAESU → 14 models
        case tenTecModel           // Nested: CAT → TEN-TEC → 4 models
        case baudRate              // Final CAT sub-menu: 8 speed choices
        case tunAntPort            // Nested TUN ANT → PORT config

        /// Number of navigable items in each sub-menu
        var itemCount: Int {
            switch self {
            case .config: return 6      // BNK A, BNK B, REMOTE ANT, SO2R, COMBINER, SAVE
            case .antenna: return 23    // 11 bands x 2 slots + SAVE
            case .cat: return 9         // NONE, ICOM, KENWOOD, YAESU, TEN-TEC, FLEX, ELCRAFT, BAND DATA, EXIT
            case .manualTune: return 0  // Uses L±/C± buttons directly
            case .display: return 0     // Uses L±/C± buttons directly
            case .beep: return 0        // Toggle only
            case .start: return 0       // Toggle only
            case .tempFans: return 3    // TEMP SCALE, FAN MGMT, SAVE
            case .tunAnt: return 6      // ANT1-4, PORT, SAVE
            case .rxAnt: return 4       // ANT2-4, SAVE
            case .alarmsLog: return 0   // Scroll with arrows, SET to quit
            case .yaesuModel: return 14
            case .tenTecModel: return 4
            case .baudRate: return 8
            case .tunAntPort: return 8    // Only the 8 baud rates are cursor-selectable; left-side fields are display-only.
            }
        }
    }

    /// Menu items in navigation order (column-first: down each column, then next column)
    /// Column 1: CONFIG, ANTENNA, CAT, MANUAL TUNE
    /// Column 2: DISPLAY, BEEP, START, TEMP/FANS
    /// Column 3: ALARMS LOG, TUN ANT, RX ANT, EXIT
    static let setupMenuItems = [
        "CONFIG", "ANTENNA", "CAT", "MANUAL TUNE",
        "DISPLAY", "BEEP", "START", "TEMP/FANS",
        "ALARMS LOG", "TUN ANT", "RX ANT", "EXIT",
    ]

    /// Map navigation index to grid position (row, column) for display
    static let setupNavToGrid: [(row: Int, col: Int)] = [
        (0, 0), (1, 0), (2, 0), (3, 0),  // Column 1
        (0, 1), (1, 1), (2, 1), (3, 1),  // Column 2
        (0, 2), (1, 2), (2, 2), (3, 2),  // Column 3
    ]

    // Serial settings
    var selectedPortPath: String = "" {
        didSet { UserDefaults.standard.set(selectedPortPath, forKey: "serialPortPath") }
    }
    var baudRate: Int = 115200 {
        didSet { UserDefaults.standard.set(baudRate, forKey: "baudRate") }
    }
    var availablePorts: [ORSSerialPort] = []

    // WebSocket settings
    var wsHost: String = "192.168.1.100" {
        didSet { UserDefaults.standard.set(wsHost, forKey: "wsHost") }
    }
    var wsPort: Int = 8888 {
        didSet { UserDefaults.standard.set(wsPort, forKey: "wsPort") }
    }

    // MARK: - Private
    private var connection: ConnectionProvider?
    private var portObserver: NSObjectProtocol?

    init() {
        loadSettings()
        refreshPorts()
        observePortChanges()
        // Auto-reconnect after a small delay so SwiftUI has time to
        // build the view hierarchy first (otherwise connection-error
        // toasts can fire before there's anything to display them).
        if autoReconnectOnLaunch && hasUsableLastConnection {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                connect()
            }
        }
    }

    /// True when persisted settings include enough to attempt a
    /// reconnect to the last-known transport (a serial port path for
    /// .serial, a host for .websocket).
    private var hasUsableLastConnection: Bool {
        switch connectionMode {
        case .serial:    return !selectedPortPath.isEmpty
        case .websocket: return !wsHost.isEmpty && wsPort > 0
        }
    }

    // MARK: - Connection

    func connect() {
        Task {
            do {
                disconnect()

                switch connectionMode {
                case .serial:
                    let serial = SerialConnection(portPath: selectedPortPath, baudRate: baudRate)
                    serial.onStateUpdate = { [weak self] state in
                        self?.handleStateUpdate(state)
                    }
                    serial.onConnectionChange = { [weak self] connected in
                        self?.isConnected = connected
                        self?.statusMessage = connected ? "Connected (Serial)" : "Disconnected"
                    }
                    serial.onRCUDisplayPacket = { [weak self] packet in
                        guard let self else { return }
                        self.rcuCallbackCount += 1
                        self.rcuLastCallbackAt = Date()
                        self.markAmpTraffic()
                        self.captureLogger.append(packet: [UInt8](packet))
                        self.handleRCUFrame(packet)
                    }
                    serial.onRawBytes = { [weak self] chunk in
                        self?.captureLogger.appendRaw(bytes: chunk)
                    }
                    serial.onRCUTick = { [weak self] in
                        self?.rcuTicksSent += 1
                    }
                    connection = serial
                    try await serial.connect()

                case .websocket:
                    guard let url = URL(string: "ws://\(wsHost):\(wsPort)/ws") else {
                        errorMessage = "Invalid WebSocket URL"
                        return
                    }
                    let ws = WebSocketConnection(url: url)
                    ws.onStateUpdate = { [weak self] state in
                        self?.handleStateUpdate(state)
                    }
                    ws.onConnectionChange = { [weak self] connected in
                        self?.isConnected = connected
                        self?.statusMessage = connected ? "Connected (WebSocket)" : "Disconnected"
                    }
                    // RCU frames arrive as binary WS messages when the Pi's
                    // spe-remote is running a build that proxies them. The
                    // pipeline is identical to serial from here on — parse,
                    // update view state, bump counters.
                    ws.onRCUDisplayPacket = { [weak self] packet in
                        guard let self else { return }
                        self.rcuCallbackCount += 1
                        self.rcuLastCallbackAt = Date()
                        self.markAmpTraffic()
                        self.captureLogger.append(packet: [UInt8](packet))
                        self.handleRCUFrame(packet)
                    }
                    ws.onRCUTick = { [weak self] in
                        self?.rcuTicksSent += 1
                    }
                    connection = ws
                    try await ws.connect()
                }

                errorMessage = ""
            } catch {
                errorMessage = error.localizedDescription
                isConnected = false
            }
        }
    }

    func disconnect() {
        // Make sure any in-flight capture is flushed and RCU is left off.
        if captureLogger.isRunning {
            stopCapture()
        }
        // If SETUP mode owns RCU, release it too so the next session starts
        // with the amp in CSV polling.
        if rcuOwner == .setupMode {
            exitSetupRCU()
        }
        connection?.disconnect()
        connection = nil
        isConnected = false
        statusMessage = "Disconnected"
        rcuFrame = nil
    }

    // MARK: - RCU Capture

    /// Open a capture file and start writing every incoming 0x6A frame to
    /// it. The RCU ticker is already running (it's always-on while connected),
    /// so no RCU lifecycle work is needed here.
    func startCapture(label: String) {
        captureErrorMessage = ""
        do {
            _ = try captureLogger.start(label: label)
        } catch {
            captureErrorMessage = "Couldn't open capture file: \(error.localizedDescription)"
            return
        }
        if rcuOwner == .none { rcuOwner = .capture }
    }

    /// Close the capture file. RCU stays on — it's always on while connected.
    func stopCapture() {
        if rcuOwner == .capture { rcuOwner = .none }
        captureLogger.stop()
    }

    /// Force the amp to emit one fresh frame (useful after a label change
    /// in Capture — the next tick will also produce one within ~400 ms, so
    /// this is optional).
    func grabOneFrame() {
        guard captureLogger.isRunning, connection is SerialConnection else { return }
        Task { [weak self] in
            self?.connection?.sendCommand(.rcuOff)
            try? await Task.sleep(for: .milliseconds(80))
            self?.connection?.sendCommand(.rcuOn)
        }
    }

    // MARK: - RCU in SETUP mode

    /// Record entry into SETUP mode for the auto-exit grace period. RCU is
    /// always on while connected, so there's no hardware toggle to do here.
    private func enterSetupRCU() {
        setupEnteredAt = Date()
        if rcuOwner == .none { rcuOwner = .setupMode }
    }

    /// Walk the cursor through all 11 bands on the ANTENNA matrix screen to
    /// populate `antennaMatrix` with every band's slot-1 value.
    ///
    /// Preconditions:
    ///   - user must already be on the ANTENNA screen (activeSubMenu == .antenna)
    ///   - serial connection is live
    ///
    /// Strategy:
    ///   - Press LEFT 12 times to guarantee cursor wraps back to the first band.
    ///   - For each of 11 bands: wait briefly, then press RIGHT.
    ///   - Each frame between keypresses fills one map entry via handleRCUFrame.
    var isScanningAntennaMatrix: Bool = false

    func scanAntennaMatrix() {
        guard activeSubMenu == .antenna,
              connection is SerialConnection,
              !isScanningAntennaMatrix else { return }
        isScanningAntennaMatrix = true
        Task { [weak self] in
            defer { Task { @MainActor in self?.isScanningAntennaMatrix = false } }
            // Rewind to start: 12 left presses (> 11 bands) ensures we land
            // on the first band no matter where the cursor is now.
            for _ in 0..<12 {
                await MainActor.run { self?.connection?.sendCommand(.leftArrow) }
                try? await Task.sleep(for: .milliseconds(150))
            }
            // Walk right through all 11 bands; each step triggers a new RCU
            // frame which handleRCUFrame uses to populate antennaMatrix.
            for _ in 0..<11 {
                try? await Task.sleep(for: .milliseconds(450))  // let the frame arrive
                await MainActor.run { self?.connection?.sendCommand(.rightArrow) }
            }
            try? await Task.sleep(for: .milliseconds(450))  // final frame
        }
    }

    /// Manually force the amp to emit a fresh frame NOW. RCU is already
    /// running, so this is just an out-of-cycle OFF→ON to get an immediate
    /// snapshot without waiting for the next 400 ms tick.
    func syncFromAmp() {
        guard connection is SerialConnection else { return }
        Task { [weak self] in
            self?.connection?.sendCommand(.rcuOff)
            try? await Task.sleep(for: .milliseconds(120))
            self?.connection?.sendCommand(.rcuOn)
        }
    }

    /// Release SETUP ownership marker. RCU stays on — it's always on while
    /// connected now.
    private func exitSetupRCU() {
        guard rcuOwner == .setupMode else { return }
        rcuOwner = .none
    }

    func sendCommand(_ command: SPECommand) {
        // Note the time of cursor-nav commands so handleRCUFrame can
        // ignore stale RCU-frame cursor values that haven't caught up yet.
        if command == .leftArrow || command == .rightArrow {
            lastNavCommandAt = Date()
        }
        // Light the TUNE LED for the duration of an app-initiated tune.
        if command == .tune {
            isTuningInProgress = true
            tuneTimeoutTask?.cancel()
            tuneTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.tuneTimeoutDuration ?? 5))
                await MainActor.run { self?.isTuningInProgress = false }
            }
        }
        // Track local DISPLAY-screen brightness/contrast counter so the
        // app's bars stay perfectly smooth regardless of the amp's
        // ambiguous LCD encoding.
        if activeSubMenu == .display {
            switch command {
            case .lPlus:  localBacklightLevel = min(Self.displayLevelMax, localBacklightLevel + 1)
            case .lMinus: localBacklightLevel = max(Self.displayLevelMin, localBacklightLevel - 1)
            case .cPlus:  localContrastLevel  = min(Self.displayLevelMax, localContrastLevel + 1)
            case .cMinus: localContrastLevel  = max(Self.displayLevelMin, localContrastLevel - 1)
            default: break
            }
        }
        // Track setup mode state
        if let subMenu = activeSubMenu {
            // Inside a sub-menu
            if command == .set {
                // Check if cursor is on SAVE/EXIT/QUIT item (last item)
                let lastIndex = subMenu.itemCount - 1
                if subMenu.itemCount == 0 || subMenuCursorIndex >= lastIndex {
                    // Exit sub-menu back to main setup menu
                    withAnimation(.easeInOut(duration: 0.15)) {
                        activeSubMenu = nil
                        subMenuCursorIndex = 0
                    }
                }
            } else if subMenu.itemCount > 0 {
                switch command {
                case .rightArrow:
                    withAnimation(.easeInOut(duration: 0.15)) {
                        subMenuCursorIndex = (subMenuCursorIndex + 1) % subMenu.itemCount
                    }
                case .leftArrow:
                    withAnimation(.easeInOut(duration: 0.15)) {
                        subMenuCursorIndex = (subMenuCursorIndex - 1 + subMenu.itemCount) % subMenu.itemCount
                    }
                default:
                    break
                }
            }
            connection?.sendCommand(command)
            return
        }

        if command == .set {
            if !isInSetupMode {
                // The amp's firmware only allows SETUP entry from STANDBY —
                // pressing SET in OPERATE is a no-op on the amp. Mirror that
                // here so MacExpert doesn't appear to enter a mode the amp
                // can't actually be in.
                guard state.opStatus != "Oper" else {
                    errorMessage = "SETUP is only available in STANDBY mode."
                    // Auto-clear after 3s so it doesn't linger.
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(3))
                        await MainActor.run {
                            if self?.errorMessage == "SETUP is only available in STANDBY mode." {
                                self?.errorMessage = ""
                            }
                        }
                    }
                    return  // don't send the command either
                }
                withAnimation(.easeInOut(duration: 0.15)) {
                    isInSetupMode = true
                    setupCursorIndex = 0
                }
                // Entering SETUP: take RCU ownership so physical amp-panel
                // navigation flows back to our UI.
                enterSetupRCU()
            } else {
                // SET pressed on a menu item — enter sub-menu or exit
                let exitIndex = Self.setupMenuItems.count - 1
                if setupCursorIndex == exitIndex {
                    // EXIT
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isInSetupMode = false
                        activeSubMenu = nil
                    }
                    exitSetupRCU()
                } else {
                    // Enter the sub-menu for the current item
                    let subMenu = subMenuForIndex(setupCursorIndex)
                    withAnimation(.easeInOut(duration: 0.15)) {
                        activeSubMenu = subMenu
                        subMenuCursorIndex = initialCursorForSubMenu(subMenu)
                    }
                    // BEEP (5) / START (6) are in-place toggles — flip our
                    // local mirror so the SETUP grid shows the new state
                    // next to the item name. Nil → true on first press, so
                    // the user sees confirmation that MacExpert caught the
                    // SET even before they know the real starting state.
                    if setupCursorIndex == 5 {
                        beepOn = !(beepOn ?? false)
                    } else if setupCursorIndex == 6 {
                        startInOperate = !(startInOperate ?? false)
                    }
                }
            }
        } else if isInSetupMode {
            switch command {
            case .rightArrow:
                withAnimation(.easeInOut(duration: 0.15)) {
                    setupCursorIndex = (setupCursorIndex + 1) % Self.setupMenuItems.count
                }
            case .leftArrow:
                withAnimation(.easeInOut(duration: 0.15)) {
                    setupCursorIndex = (setupCursorIndex - 1 + Self.setupMenuItems.count) % Self.setupMenuItems.count
                }
            default:
                break
            }
        }
        connection?.sendCommand(command)
    }

    func exitSubMenu() {
        withAnimation(.easeInOut(duration: 0.15)) {
            activeSubMenu = nil
            subMenuCursorIndex = 0
        }
    }

    func exitSetupMode() {
        isInSetupMode = false
        activeSubMenu = nil
        setupCursorIndex = 0
        exitSetupRCU()
    }

    private func initialCursorForSubMenu(_ subMenu: SetupSubMenu?) -> Int {
        guard let subMenu else { return 0 }
        switch subMenu {
        case .config:
            // Start on BNK B (index 1) if bank B is active, else BNK A (index 0)
            return (state.memBank == "B" || state.memBank == "x") ? 1 : 0
        case .tunAnt:
            // Start on the currently-selected antenna (ANT1-4) so the user
            // is positioned on the antenna the amp would actually tune if
            // they pressed TUNE right now. state.antenna is "1".."4";
            // cursor indices 0-3 map directly to ANT1-ANT4.
            if let n = Int(state.txAntenna), (1...4).contains(n) {
                return n - 1
            }
            return 0
        default:
            return 0
        }
    }

    private func subMenuForIndex(_ index: Int) -> SetupSubMenu? {
        // BEEP (index 5) and START (index 6) are toggles on the amp —
        // pressing SET on them just flips the setting, no sub-menu opens.
        // Returning nil here lets the SET handler treat them as
        // "forward the key press and stay on the root SETUP screen".
        let subMenus: [SetupSubMenu?] = [
            .config, .antenna, .cat, .manualTune,
            .display, nil, nil, .tempFans,
            .alarmsLog, .tunAnt, .rxAnt, nil, // EXIT has no sub-menu
        ]
        guard index < subMenus.count else { return nil }
        return subMenus[index]
    }

    /// Power on the amplifier (DTR toggle for serial, command for WebSocket).
    func powerOn() {
        guard let connection else {
            errorMessage = "Not connected"
            return
        }
        Task {
            await connection.powerOn()
        }
    }

    func powerOff() {
        if connectionMode == .websocket, let ws = connection as? WebSocketConnection {
            ws.sendRawCommand("power_off")
        } else {
            sendCommand(.switchOff)
        }
    }

    // MARK: - Port Management

    func refreshPorts() {
        availablePorts = SerialConnection.availablePorts
        if selectedPortPath.isEmpty, let first = availablePorts.first {
            selectedPortPath = first.path
        }
    }

    // MARK: - Private

    /// Parse an incoming 0x6A RCU display payload and sync UI state from it.
    /// Called for every frame received while RCU is active (whether SETUP or
    /// Capture owns the stream).
    private func handleRCUFrame(_ data: Data) {
        guard let frame = RCUFrame.parse(data) else { return }
        rcuFrame = frame
        rcuFrameCount += 1

        // Take bank letter from the frame — it's direct from the amp's LCD
        // so it's the freshest source of truth while we're in RCU mode.
        if let letter = frame.bankLetter {
            state.memBank = String(letter)
        }

        // Suppress cursor updates from RCU frames for a short window after
        // the user pressed ◀/▶ in the app — otherwise a stale RCU frame
        // (from before the amp processed our nav command) will bounce the
        // cursor back to the old position.
        let suppressCursor = lastNavCommandAt.map {
            Date().timeIntervalSince($0) < navSuppressionWindow
        } ?? false

        switch frame.screen {
        case .setupRoot:
            withAnimation(.easeInOut(duration: 0.15)) {
                isInSetupMode = true
                activeSubMenu = nil
                if !suppressCursor,
                   let idx = frame.gridCursorNavIndex,
                   idx < Self.setupMenuItems.count {
                    setupCursorIndex = idx
                }
            }

        case .catMenu:
            withAnimation(.easeInOut(duration: 0.15)) {
                isInSetupMode = true
                activeSubMenu = .cat
                if !suppressCursor,
                   let idx = frame.gridCursorNavIndex,
                   idx < SetupSubMenu.cat.itemCount {
                    subMenuCursorIndex = idx
                }
            }
            // The cursor lands on the currently-selected CAT on entry —
            // cache it so the CAT status chip has a value without waiting
            // for a baud rate frame.
            if let idx = frame.gridCursorNavIndex,
               idx >= 0 && idx < Self.catMenuItems.count - 1 /* skip EXIT */ {
                cachedCatType = Self.catMenuItems[idx]
            }

        case .config:
            withAnimation(.easeInOut(duration: 0.15)) {
                isInSetupMode = true
                activeSubMenu = .config
                if !suppressCursor,
                   let idx = frame.gridCursorNavIndex,
                   idx < SetupSubMenu.config.itemCount {
                    subMenuCursorIndex = idx
                }
            }

        case .antennaMatrix:
            isInSetupMode = true
            activeSubMenu = .antenna
            // The amp's matrix view renders every band's (slot1, slot2) in
            // one frame. Parse the whole thing and update the map.
            //
            // We used to skip cursored bands that showed "NO NO", assuming
            // that was a cursor overlay masking the real values. In
            // practice the amp's LCD always displays the *live* value in
            // the cell (including the cursor's pending selection), so
            // skipping made legitimate NO-NO selections and mid-edit
            // previews invisible until the user navigated elsewhere. The
            // fix is to always trust the LCD text — update every band's
            // slot pair on every matrix frame.
            if let bank = frame.bankLetter, let matrix = frame.antennaMatrixValues {
                for (band, slots) in matrix {
                    antennaMatrix["\(bank)/\(band)"] = slots
                }
            }

        case .display:
            isInSetupMode = true
            activeSubMenu = .display

        case .alarmsLog:
            isInSetupMode = true
            activeSubMenu = .alarmsLog

        case .tempFans:
            withAnimation(.easeInOut(duration: 0.15)) {
                isInSetupMode = true
                activeSubMenu = .tempFans
                if !suppressCursor,
                   let idx = frame.gridCursorNavIndex,
                   idx < SetupSubMenu.tempFans.itemCount {
                    subMenuCursorIndex = idx
                }
            }
            // Cache the amp's selected temperature unit so the main
            // power/gauge view picks the right unit + scale on every
            // subsequent render (including future launches via
            // UserDefaults).
            //
            // The amp's TEMP/FANS screen prints "CELSIUS" or
            // "FAHRENHEIT" (the latter properly spelled — earlier
            // notes that called it "FARENHEIT" were wrong, see captured
            // screenshots from 2026-05-07). We pivot on the first
            // letter, which uniquely identifies either option:
            //    'F' → Fahrenheit, 'C' → Celsius.
            //
            // Only flip on a POSITIVE marker match. If we can't
            // confidently identify either letter (transient/partial
            // read while navigating into the sub-menu), leave the
            // cached value alone — otherwise an ambiguous read would
            // silently clobber a manually-set unit (the old "F → C
            // auto-flips, C → F never does" symptom).
            if let scale = frame.temperatureScale?.uppercased(),
               let first = scale.first {
                if first == "F" {
                    if cachedTempUnit != "F" { cachedTempUnit = "F" }
                } else if first == "C" {
                    if cachedTempUnit != "C" { cachedTempUnit = "C" }
                }
                // else: ambiguous read — keep current cached value.
            }

        case .manualTune:
            isInSetupMode = true
            activeSubMenu = .manualTune

        case .rxAnt:
            withAnimation(.easeInOut(duration: 0.15)) {
                isInSetupMode = true
                activeSubMenu = .rxAnt
                if !suppressCursor,
                   let idx = frame.gridCursorNavIndex,
                   idx < SetupSubMenu.rxAnt.itemCount {
                    subMenuCursorIndex = idx
                }
            }

        case .tunAnt:
            withAnimation(.easeInOut(duration: 0.15)) {
                isInSetupMode = true
                activeSubMenu = .tunAnt
                if !suppressCursor,
                   let idx = frame.gridCursorNavIndex,
                   idx < SetupSubMenu.tunAnt.itemCount {
                    subMenuCursorIndex = idx
                }
            }

        case .opStandby, .opOperate, .antennaNotAvailable:
            // The amp drops to the main screen (standby or operate) after
            // SAVE or EXIT in any sub-menu — that's our signal to take
            // MacExpert out of SETUP mode too. But ignore these frames for
            // the first 800ms after entering SETUP: the amp can briefly
            // flash a stale frame while it's still processing the SET
            // command that put us in SETUP, and we don't want to bounce
            // right back out.
            let justEntered = setupEnteredAt.map { Date().timeIntervalSince($0) < 0.4 } ?? false
            if isInSetupMode && !justEntered {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isInSetupMode = false
                    activeSubMenu = nil
                }
                exitSetupRCU()
            }
            // A non-info frame closes any open info overlay.
            if isShowingInfoScreen {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isShowingInfoScreen = false
                    infoScreenLines = []
                }
            }
            // Refresh the standby banner text from the current frame
            // (only when we're actually in STANDBY — in OPERATE the
            // banner hides so the live power meter takes over again).
            if frame.screen == .opStandby {
                let banner = Self.decodeInfoScreenLines(from: frame.raw)
                if banner != standbyBannerLines { standbyBannerLines = banner }
            } else if !standbyBannerLines.isEmpty {
                standbyBannerLines = []
            }

        case .infoScreen:
            // Read-only CAT / DISP info panel. Take the title from the
            // frame's parsed header row; decode the body separately so
            // we don't duplicate header text in the body segments.
            withAnimation(.easeInOut(duration: 0.15)) {
                isShowingInfoScreen = true
                infoScreenTitle = frame.header
                infoScreenLines = Self.decodeInfoScreenLines(
                    from: frame.raw, headerTitle: frame.header)
            }
            lastInfoFrameAt = Date()
            scheduleInfoScreenAutoClear()

        case .yaesuModel:
            withAnimation(.easeInOut(duration: 0.15)) {
                isInSetupMode = true
                activeSubMenu = .yaesuModel
                if !suppressCursor,
                   let idx = frame.gridCursorNavIndex,
                   idx < SetupSubMenu.yaesuModel.itemCount {
                    subMenuCursorIndex = idx
                }
            }

        case .tenTecModel:
            withAnimation(.easeInOut(duration: 0.15)) {
                isInSetupMode = true
                activeSubMenu = .tenTecModel
                if !suppressCursor,
                   let idx = frame.gridCursorNavIndex,
                   idx < SetupSubMenu.tenTecModel.itemCount {
                    subMenuCursorIndex = idx
                }
            }

        case .baudRate:
            withAnimation(.easeInOut(duration: 0.15)) {
                isInSetupMode = true
                activeSubMenu = .baudRate
                if !suppressCursor,
                   let idx = frame.gridCursorNavIndex,
                   idx < SetupSubMenu.baudRate.itemCount {
                    subMenuCursorIndex = idx
                }
            }
            // The baud rate screen prints "CAT: YAESU" (etc) — freshen the
            // cache so it survives even if user skips the CAT menu.
            if let cat = frame.baudRateCatType, !cat.isEmpty {
                cachedCatType = cat
            }

        case .tunAntPort:
            withAnimation(.easeInOut(duration: 0.15)) {
                isInSetupMode = true
                activeSubMenu = .tunAntPort
                if !suppressCursor,
                   let idx = frame.gridCursorNavIndex,
                   idx < SetupSubMenu.tunAntPort.itemCount {
                    subMenuCursorIndex = idx
                }
            }

        case .unknown:
            break
        }
    }

    /// Decode the first ~320 bytes of an RCU frame into 40-char rows using
    /// the LCD attribute scheme. The amp's LCD is 40 columns wide; we
    /// show every row so we don't have to know in advance which info
    /// screen we're looking at. Empty / whitespace-only rows are kept so
    /// spacing in the output matches the amp's panel.
    /// Restart the 2-second info-screen watchdog. Each info-screen frame
    /// calls this; if no new info frame arrives within the window (i.e.
    /// the amp transitioned back to standby/operate and we either
    /// misclassified that frame or didn't receive it), auto-clear the
    /// overlay so the user isn't stuck looking at a stale panel.
    private func scheduleInfoScreenAutoClear() {
        infoScreenAutoClearTask?.cancel()
        infoScreenAutoClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                // Only clear if no fresher frame has been recorded since
                // this task was scheduled.
                guard let last = self.lastInfoFrameAt,
                      Date().timeIntervalSince(last) >= 1.9 else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    self.isShowingInfoScreen = false
                    self.infoScreenLines = []
                }
            }
        }
    }

    /// Mark traffic as just received from the amp. Called by both
    /// handleStateUpdate (CSV) and the RCU display-packet handler so
    /// the watchdog stays accurate even when the Pi suppresses
    /// identical CSV JSON.
    func markAmpTraffic() {
        lastTrafficAt = Date()
        if !isAmpResponding {
            isAmpResponding = true
        }
        startAmpWatchdogIfNeeded()
    }

    /// Start a 1 Hz watchdog that flips `isAmpResponding` to false when
    /// no traffic has arrived for more than 4 seconds. Triggers a
    /// SwiftUI re-render so the main view can show "POWERED OFF"
    /// instead of a stale STANDBY banner.
    private func startAmpWatchdogIfNeeded() {
        guard ampWatchdogTask == nil else { return }
        ampWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                await MainActor.run {
                    let stale = self.lastTrafficAt
                        .map { Date().timeIntervalSince($0) >= 4.0 } ?? true
                    let nowResponding = !stale
                    if self.isAmpResponding != nowResponding {
                        self.isAmpResponding = nowResponding
                    }
                }
            }
        }
    }

    static func decodeInfoScreenLines(from raw: [UInt8], headerTitle: String = "") -> [String] {
        // The amp's LCD row width differs by screen (some 40, some 32),
        // and splitting the body at the wrong width butchers words —
        // e.g. "AUTOMATIC" breaks into "AUTOMA" / "TIC" on separate
        // rows. Instead of guessing the width, decode the whole body
        // region (bytes 32-191) as one string and split on runs of 3+
        // spaces, which the amp uses as natural field/row separators.
        // Each resulting segment is a clean word-group; the view centres
        // them one per line.
        let end = min(192, raw.count)
        guard end >= 32 else { return [] }
        let raw = LCDText.decode(raw[32..<end])
            .replacingOccurrences(of: ".", with: " ")
        // Tokens from the title we should drop if they appear at the
        // very start of the body (tail of a long header spilling past
        // byte 31). E.g. header "CAT SETTING REPORT INP" → body starts
        // with "UT 1" — we suppress that fragment.
        let titleTail: Set<String> = {
            let words = headerTitle
                .uppercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
            return Set(words.suffix(2))   // last 1-2 header words
        }()
        // Split on runs of 3+ spaces, trim each segment, drop empties.
        var segments: [String] = []
        var current = ""
        var spaceRun = 0
        for ch in raw {
            if ch == " " {
                spaceRun += 1
                if spaceRun >= 3 && !current.isEmpty {
                    segments.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                }
            } else {
                if spaceRun > 0 && !current.isEmpty && spaceRun < 3 {
                    // Keep small gaps inside a segment so "SN:0656"
                    // style labels stay intact.
                    current.append(" ")
                }
                spaceRun = 0
                current.append(ch)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            segments.append(current.trimmingCharacters(in: .whitespaces))
        }
        // Drop a leading segment that's only a fragment of the header
        // tail (e.g. "RT" from "CAT SETTING REPORT", or "UT" from
        // "...INPUT"). Anything shorter than 3 chars AND matching a
        // trailing word fragment of the title is noise.
        if let first = segments.first {
            let upper = first.uppercased()
            if first.count <= 3 && titleTail.contains(where: { $0.hasSuffix(upper) }) {
                segments.removeFirst()
            }
        }
        return segments
    }

    private func handleStateUpdate(_ newState: AmplifierState) {
        state = newState
        lastStateUpdateAt = Date()
        markAmpTraffic()

        // Auto-detect model from ID field (serial mode)
        if !newState.modelId.isEmpty {
            let model = AmplifierModel.detect(from: newState.modelId)
            if model != .unknown {
                detectedModel = model
            }
        }

        // Auto-learn antenna mapping from status
        antennaMap.learn(
            band: newState.band,
            antenna: newState.txAntenna,
            atu: newState.atuStatus
        )

        // Physical TUNE-button detection: not currently implemented.
        // The SPE CSV protocol (per the Application Programmer's Guide)
        // exposes no dedicated "tune in progress" bit. Warning code "W"
        // (TUNING WITH NO POWER) only appears when the user pressed TUNE
        // but no RF drive arrived — so a successful tune never raises it,
        // making "W" unreliable as a tune-running signal. For now the
        // TUNE LED is driven exclusively by the app-initiated 5s timer
        // set in `sendCommand(.tune)`.
    }

    private func loadSettings() {
        if let path = UserDefaults.standard.string(forKey: "serialPortPath") {
            selectedPortPath = path
        }
        let savedBaud = UserDefaults.standard.integer(forKey: "baudRate")
        if savedBaud > 0 { baudRate = savedBaud }

        if let host = UserDefaults.standard.string(forKey: "wsHost"), !host.isEmpty {
            wsHost = host
        }
        let savedWSPort = UserDefaults.standard.integer(forKey: "wsPort")
        if savedWSPort > 0 { wsPort = savedWSPort }

        if let modeRaw = UserDefaults.standard.string(forKey: "connectionMode"),
           let mode = ConnectionMode(rawValue: modeRaw) {
            connectionMode = mode
        }
        // Auto-reconnect default is true; only honour a stored "false"
        // (UserDefaults.bool returns false for missing keys, which we
        // don't want to misread as "user disabled it").
        if UserDefaults.standard.object(forKey: "autoReconnectOnLaunch") != nil {
            autoReconnectOnLaunch = UserDefaults.standard.bool(forKey: "autoReconnectOnLaunch")
        }
    }

    private func observePortChanges() {
        portObserver = NotificationCenter.default.addObserver(
            forName: .ORSSerialPortsWereConnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPorts()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .ORSSerialPortsWereDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPorts()
            }
        }
    }
}
