import Foundation

/// The radio-settings sheet's form, kept apart from the view so the
/// overlay, validation and payload rules are unit-tested.
///
/// Fields are strings, as typed. ``problems`` mirrors spe-remote's
/// `_RADIO_FIELD_RULES` (websocket_handler.py), so a value the Pi would
/// refuse is caught here: a non-numeric or out-of-range field is reported
/// instead of being silently replaced by a default. ``payload()`` is nil
/// while there are problems.
struct RadioForm: Equatable {
    var kind = "none"
    var flexHost = ""
    var flexPort = "4992"
    var flexSlice = "0"
    var flexPower = "10"
    var tciHost = "127.0.0.1"
    var tciPort = "50001"
    var tciTrx = "0"
    var tciMode = "CW"
    var tciDrive = "0"

    init() {}

    /// `base` with the Pi's config laid over it. A field the Pi omits keeps
    /// its value from `base`, as the sheet always did.
    init(_ cfg: RadioConfig, over base: RadioForm = RadioForm()) {
        self = base
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

    /// What's wrong with the active kind's fields, one line each, in form
    /// order. Empty means Apply may send.
    var problems: [String] {
        var out: [String] = []
        switch kind {
        case "flex":
            // An empty Flex host is allowed: spe-remote auto-discovers.
            if let p = Self.hostProblem("Host", flexHost, required: false) { out.append(p) }
            if let p = Self.intProblem("Port", flexPort, 1...65535) { out.append(p) }
            if let p = Self.intProblem("Slice", flexSlice, 0...7) { out.append(p) }
            if let p = Self.intProblem("Tune W", flexPower, 1...100) { out.append(p) }
        case "tci":
            // spe-remote accepts an empty TCI host but can't connect with it
            // ("tci.host is empty"), so it's asked for here.
            if let p = Self.hostProblem("Host", tciHost, required: true) { out.append(p) }
            if let p = Self.intProblem("Port", tciPort, 1...65535) { out.append(p) }
            if let p = Self.intProblem("TRX", tciTrx, 0...1) { out.append(p) }
            let mode = tciMode.trimmingCharacters(in: .whitespaces)
            if mode.isEmpty || mode.count > 10 || !mode.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
                out.append("Mode must be a mode name such as CW (letters and digits, up to 10)")
            }
            if let p = Self.intProblem("Tune %", tciDrive, 0...100) { out.append(p) }
        default:
            break
        }
        return out
    }

    /// The `set_radio_config` body for the active kind, or nil while
    /// ``problems`` isn't empty.
    func payload() -> [String: Any]? {
        guard problems.isEmpty else { return nil }
        var p: [String: Any] = ["kind": kind]
        switch kind {
        case "flex":
            p["flex"] = [
                "host": flexHost.trimmingCharacters(in: .whitespaces),
                "port": Self.int(flexPort)!,
                "slice_rx": Self.int(flexSlice)!,
                "tune_power_watts": Self.int(flexPower)!,
            ]
        case "tci":
            p["tci"] = [
                "host": tciHost.trimmingCharacters(in: .whitespaces),
                "port": Self.int(tciPort)!,
                "trx": Self.int(tciTrx)!,
                "mode": tciMode.trimmingCharacters(in: .whitespaces).uppercased(),
                "tune_drive": Self.int(tciDrive)!,
            ]
        default:
            break
        }
        return p
    }

    // MARK: - Field rules

    private static func int(_ s: String) -> Int? {
        Int(s.trimmingCharacters(in: .whitespaces))
    }

    private static func intProblem(_ label: String, _ s: String, _ range: ClosedRange<Int>) -> String? {
        guard let n = int(s) else {
            return "\(label) must be a whole number (\(range.lowerBound)–\(range.upperBound))"
        }
        return range.contains(n) ? nil : "\(label) must be \(range.lowerBound)–\(range.upperBound)"
    }

    private static func hostProblem(_ label: String, _ s: String, required: Bool) -> String? {
        let host = s.trimmingCharacters(in: .whitespaces)
        if host.isEmpty { return required ? "\(label) is required" : nil }
        if host.contains(where: \.isWhitespace) || host.count > 255 {
            return "\(label) must be a hostname or IP address"
        }
        return nil
    }
}
