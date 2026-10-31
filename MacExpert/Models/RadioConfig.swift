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

/// Envelope spe-remote wraps the config in:
/// `{"config_event":"radio","persisted":true,"radio":{…}}`.
/// Decoded ahead of AmplifierState in the WS message router so the radio
/// snapshot isn't mistaken for a (mostly-defaulted) state frame.
struct RadioConfigMessage: Decodable {
    let configEvent: String
    let radio: RadioConfig
    /// False when the Pi applied a `set_radio_config` live but couldn't
    /// write config.yaml, so the change reverts on restart. Absent from
    /// older servers. A `get_config` reply always says true, so only the
    /// broadcast right before `RADIO_CONFIG_UPDATED` is meaningful.
    let persisted: Bool?

    enum CodingKeys: String, CodingKey {
        case configEvent = "config_event"
        case radio
        case persisted
    }
}
