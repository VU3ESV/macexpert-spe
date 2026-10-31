import XCTest
@testable import MacExpert

/// Radio-settings follow-ups to #9: the form never sends placeholder or
/// silently-defaulted values, detects edits, and the Sweep headline names
/// the actual RADIO_ERROR.
final class RadioFormTests: XCTestCase {
    private let tciConfig = RadioConfig(
        kind: "tci", flex: nil,
        tci: .init(host: "192.168.86.55", port: 50001, trx: 1, mode: "CW", tune_drive: 20))

    // MARK: - Overlay

    func test_init_fromConfig_fillsTheActiveKind() {
        let f = RadioForm(tciConfig)
        XCTAssertEqual(f.kind, "tci")
        XCTAssertEqual(f.tciHost, "192.168.86.55")
        XCTAssertEqual(f.tciTrx, "1")
        XCTAssertEqual(f.tciDrive, "20")
    }

    func test_init_keepsBaseValuesForFieldsThePiOmits() {
        var base = RadioForm()
        base.flexHost = "flex.lan"
        let f = RadioForm(RadioConfig(kind: "tci", flex: nil, tci: .init(host: "h", port: nil, trx: nil, mode: nil, tune_drive: nil)),
                          over: base)
        XCTAssertEqual(f.flexHost, "flex.lan")
        XCTAssertEqual(f.tciPort, "50001")   // base default, the Pi sent no port
        XCTAssertEqual(f.tciHost, "h")
    }

    func test_edits_makeTheFormDifferFromWhatWasLoaded() {
        let loaded = RadioForm(tciConfig)
        var form = loaded
        XCTAssertEqual(form, loaded)
        form.tciDrive = "25"
        XCTAssertNotEqual(form, loaded)
    }

    // MARK: - Validation (mirrors spe-remote _RADIO_FIELD_RULES)

    func test_validTci_buildsTheExactPayload() throws {
        var f = RadioForm(tciConfig)
        f.tciMode = " cw "
        let p = try XCTUnwrap(f.payload())
        XCTAssertEqual(p["kind"] as? String, "tci")
        let tci = try XCTUnwrap(p["tci"] as? [String: Any])
        XCTAssertEqual(tci["host"] as? String, "192.168.86.55")
        XCTAssertEqual(tci["port"] as? Int, 50001)
        XCTAssertEqual(tci["trx"] as? Int, 1)
        XCTAssertEqual(tci["mode"] as? String, "CW")
        XCTAssertEqual(tci["tune_drive"] as? Int, 20)
        XCTAssertNil(p["flex"])
    }

    func test_nonNumericField_isAProblem_andNoPayload() {
        var f = RadioForm(tciConfig)
        f.tciPort = "50OO1"
        XCTAssertEqual(f.problems, ["Port must be a whole number (1–65535)"])
        XCTAssertNil(f.payload(), "must not fall back to a default port")
    }

    func test_outOfRangeFields_areProblems() {
        var f = RadioForm(tciConfig)
        f.tciTrx = "2"
        f.tciDrive = "101"
        XCTAssertEqual(f.problems, ["TRX must be 0–1", "Tune % must be 0–100"])
    }

    func test_emptyTciHostAndMode_areProblems() {
        var f = RadioForm(tciConfig)
        f.tciHost = "  "
        f.tciMode = ""
        XCTAssertEqual(f.problems.count, 2)
        XCTAssertNil(f.payload())
    }

    func test_flex_allowsEmptyHostForAutoDiscovery_butChecksNumbers() throws {
        var f = RadioForm()
        f.kind = "flex"
        XCTAssertTrue(f.problems.isEmpty)
        let flex = try XCTUnwrap(f.payload()?["flex"] as? [String: Any])
        XCTAssertEqual(flex["host"] as? String, "")
        f.flexSlice = "8"
        f.flexPower = "0"
        XCTAssertEqual(f.problems, ["Slice must be 0–7", "Tune W must be 1–100"])
    }

    func test_hostWithSpaces_isAProblem() {
        var f = RadioForm()
        f.kind = "flex"
        f.flexHost = "flex radio"
        XCTAssertEqual(f.problems, ["Host must be a hostname or IP address"])
    }

    func test_none_hasNoFieldsToCheck() throws {
        let p = try XCTUnwrap(RadioForm().payload())
        XCTAssertEqual(p["kind"] as? String, "none")
        XCTAssertEqual(p.count, 1)
    }
}

final class RadioErrorHeadlineTests: XCTestCase {
    private func headline(_ message: String) -> String {
        TuneEvent(phase: "RADIO_ERROR", message: message, ts: 0).connectionErrorHeadline
    }

    // Messages as spe-remote sends them (websocket_handler.py, radio_controller.py).
    func test_headlines_nameTheActualProblem() {
        XCTAssertEqual(headline("no radio configured"), "No radio configured")
        XCTAssertEqual(headline("cannot change radio while a tune is running"), "Radio change refused — tune running")
        XCTAssertEqual(headline("bad set_radio_config: tci.port: 0 is outside 1-65535"), "Radio settings refused")
        XCTAssertEqual(headline("bad set_radio_config payload: Expecting value"), "Radio settings refused")
        XCTAssertEqual(headline("unknown radio kind 'x'"), "Radio settings refused")
        XCTAssertEqual(headline("could not write /home/pi/spe-remote/config.yaml: the radio change is live now but reverts on restart"),
                       "Radio change not saved")
        XCTAssertEqual(headline("tci.host is empty"), "Radio host not set")
    }

    func test_connectFailures_stillReadAsNotReachable() {
        XCTAssertEqual(headline("connect failed: [Errno 61] Connection refused"), "Radio not reachable")
        XCTAssertEqual(headline("discovery failed: timeout"), "Radio not reachable")
        XCTAssertEqual(headline(""), "Radio not reachable")
    }
}

final class RadioConfigMessageTests: XCTestCase {
    private func decode(_ json: String) throws -> RadioConfigMessage {
        try JSONDecoder().decode(RadioConfigMessage.self, from: Data(json.utf8))
    }

    func test_persistedFalse_isDecoded() throws {
        let m = try decode(#"{"config_event":"radio","persisted":false,"radio":{"kind":"tci","flex":{},"tci":{"host":"h","port":50001}}}"#)
        XCTAssertEqual(m.persisted, false)
        XCTAssertEqual(m.radio.kind, "tci")
    }

    func test_olderServerWithoutPersisted_stillDecodes() throws {
        let m = try decode(#"{"config_event":"radio","radio":{"kind":"none"}}"#)
        XCTAssertNil(m.persisted)
    }
}
