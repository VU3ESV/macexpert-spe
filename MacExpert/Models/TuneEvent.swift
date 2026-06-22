import Foundation

/// One phase transition emitted by spe-remote's TuneOrchestrator during a
/// single tune cycle or a band sweep. The Pi broadcasts these as plain
/// JSON on the same WebSocket as state updates / heartbeats:
///
///     {"tune_event": "<PHASE>", "tune_message": "...", "ts": 1781867...}
///
/// PHASES is the closed set the Pi emits; see spe-remote
/// `spe/tune_orchestrator.py` `PHASES` tuple. We don't enum it strictly
/// on the Swift side — new phases can land on the Pi (e.g. for the
/// upcoming MARS-only flow) without forcing a MacExpert rebuild.
/// Consumers should latch on the well-known terminal phases (SUCCESS,
/// FAIL, ABORT, SWEEP_DONE) and treat unknown phases as informational.
struct TuneEvent: Decodable, Equatable {
    let phase: String
    let message: String
    let ts: Double

    enum CodingKeys: String, CodingKey {
        case phase = "tune_event"
        case message = "tune_message"
        case ts
    }

    /// Terminal phases — the cycle is done one way or another after these.
    static let terminalPhases: Set<String> = [
        "SUCCESS", "FAIL", "ABORT", "SWEEP_DONE",
    ]

    var isTerminal: Bool { TuneEvent.terminalPhases.contains(phase) }
    var isFailure:  Bool { phase == "FAIL" || phase == "ABORT" }
    var isSweepStart: Bool { phase == "SWEEP_STARTED" }

    /// Flex connection-lifecycle phases (`FLEX_CONNECTING`,
    /// `FLEX_CONNECTED`, `FLEX_DISCONNECTED`, `FLEX_ERROR`). spe-remote
    /// now opens the SmartSDR session on demand — when the Sweep panel
    /// opens — and closes it when the cycle is over, broadcasting these
    /// on the same channel. They are not part of a tune cycle's progress,
    /// so the panel treats them separately from the tune phases above.
    var isFlexLifecycle: Bool { phase.hasPrefix("FLEX_") }

    /// Radio connection-lifecycle phases — `RADIO_CONNECTING`,
    /// `RADIO_CONNECTED`, `RADIO_DISCONNECTED`, `RADIO_ERROR`, and
    /// `RADIO_CONFIG_UPDATED`. spe-remote opens the rig on demand and may
    /// be a Flex or a SunSDR (TCI); these are not tune progress. `FLEX_`
    /// is still matched for tolerance with an older server.
    var isConnectionLifecycle: Bool {
        phase.hasPrefix("RADIO_") || phase.hasPrefix("FLEX_")
    }

    /// A connection *error* phase the UI should surface to the operator.
    var isConnectionError: Bool { phase == "RADIO_ERROR" || phase == "FLEX_ERROR" }

    /// SWEEP_STEP messages look like `"3/7: 14.1250 MHz"`. Extract the
    /// (current, total) integers for a progress bar; returns nil if the
    /// message doesn't match the format.
    var sweepProgress: (current: Int, total: Int)? {
        guard phase == "SWEEP_STEP" else { return nil }
        // Split on ":" then on "/"
        let parts = message.split(separator: ":", maxSplits: 1)
        guard let head = parts.first else { return nil }
        let nums = head.split(separator: "/")
        guard nums.count == 2,
              let current = Int(nums[0].trimmingCharacters(in: .whitespaces)),
              let total = Int(nums[1].trimmingCharacters(in: .whitespaces))
        else { return nil }
        return (current, total)
    }
}
