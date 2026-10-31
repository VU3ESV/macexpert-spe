import Foundation

/// The radio config spe-remote broadcasts as `config_event:"radio"`.
/// Mirrors `docs/CLIENT_RADIO_CONFIG.md`: the active tune backend
/// (`kind`) plus the editable settings for each kind. spe-remote sends
/// this in reply to `get_config` and after any `set_radio_config`.
///
/// All fields are optional so a partial / forward-compatible payload
/// still decodes — the settings sheet falls back to placeholders.
struct RadioConfig: Decodable, Equatable {
    var kind: String                 // "flex" | "tci" | "none"
    var flex: Flex?
    var tci: Tci?

    struct Flex: Decodable, Equatable {
        var host: String?
        var port: Int?
        var slice_rx: Int?
        var tune_power_watts: Int?
    }

    struct Tci: Decodable, Equatable {
        var host: String?
        var port: Int?
        var trx: Int?
        var mode: String?
        var tune_drive: Int?
    }
}

/// Envelope spe-remote wraps the config in: `{"config_event":"radio","radio":{…}}`.
/// Decoded ahead of AmplifierState in the WS message router so the radio
/// snapshot isn't mistaken for a (mostly-defaulted) state frame.
struct RadioConfigMessage: Decodable {
    let configEvent: String
    let radio: RadioConfig

    enum CodingKeys: String, CodingKey {
        case configEvent = "config_event"
        case radio
    }
}
