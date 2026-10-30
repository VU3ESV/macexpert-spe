import Foundation
import Observation

/// Captures raw RCU display packets to a labeled log file for offline analysis.
///
/// Lifecycle:
///   start(label:) → opens a fresh capture-YYYYMMDD-HHMMSS.log under
///   ~/Documents/Tech/MacExpert-captures/, writes a header, returns the URL.
///   append(packet:) writes one line per packet using the current label.
///   setLabel(_:) updates the label without touching the file.
///   stop() flushes and closes.
///
/// File I/O is dispatched off the main thread; UI-facing counters are updated
/// back on the main actor so SwiftUI can observe them.
@Observable
@MainActor
final class CaptureLogger {
    private(set) var isRunning: Bool = false
    private(set) var packetCount: Int = 0
    private(set) var fileURL: URL?
    var currentLabel: String = "LOGO"

    @ObservationIgnored private var fileHandle: FileHandle?
    @ObservationIgnored private var rawHandle: FileHandle?
    @ObservationIgnored private(set) var rawFileURL: URL?
    @ObservationIgnored private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Open a new capture file. Returns the URL on success, throws on failure.
    @discardableResult
    func start(label initial: String? = nil) throws -> URL {
        // Close any existing handle defensively.
        stop()

        if let initial, !initial.isEmpty {
            currentLabel = initial
        }

        let dir = try Self.captureDirectory()
        let stamp = Self.timestampForFilename()
        let url = dir.appendingPathComponent("capture-\(stamp).log")
        let rawURL = dir.appendingPathComponent("capture-\(stamp)-raw.log")

        // Create empty files so FileHandle(forWritingTo:) can open them.
        FileManager.default.createFile(atPath: url.path, contents: nil)
        FileManager.default.createFile(atPath: rawURL.path, contents: nil)

        let handle = try FileHandle(forWritingTo: url)
        let header = """
        # MacExpert RCU capture
        # Started: \(isoFormatter.string(from: Date()))
        # Format: ISO8601 | label | hex_bytes (CNT byte through last data byte, no checksum)

        """
        if let data = header.data(using: .utf8) {
            try handle.write(contentsOf: data)
        }

        let rawH = try FileHandle(forWritingTo: rawURL)
        let rawHeader = """
        # MacExpert raw byte stream (everything from amp during capture)
        # Started: \(isoFormatter.string(from: Date()))
        # Format: ISO8601 | hex_bytes
        # Use this to verify what the amp is actually sending when 0x6A parsing fails.

        """
        if let data = rawHeader.data(using: .utf8) {
            try rawH.write(contentsOf: data)
        }

        self.fileHandle = handle
        self.fileURL = url
        self.rawHandle = rawH
        self.rawFileURL = rawURL
        self.packetCount = 0
        self.isRunning = true
        return url
    }

    /// Close the capture files. Safe to call when not running.
    func stop() {
        if let handle = fileHandle {
            try? handle.synchronize()
            try? handle.close()
        }
        if let raw = rawHandle {
            try? raw.synchronize()
            try? raw.close()
        }
        fileHandle = nil
        rawHandle = nil
        isRunning = false
    }

    /// Append a raw chunk of bytes (everything received from the amp) to the
    /// raw sidecar log. Used as a ground-truth fallback when 0x6A parsing
    /// finds nothing.
    func appendRaw(bytes: Data) {
        guard isRunning, let handle = rawHandle else { return }
        let timestamp = isoFormatter.string(from: Date())
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        let line = "\(timestamp) | \(hex)\n"
        Task.detached(priority: .utility) {
            if let data = line.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
        }
    }

    /// Update the label written with subsequent packets.
    func setLabel(_ label: String) {
        currentLabel = label
    }

    /// Append one packet's data bytes to the open log. No-op when not running.
    /// Performs file I/O on a background task to avoid blocking the main actor
    /// at the 5-8 Hz packet rate; counters are bumped back on the main actor.
    func append(packet: [UInt8]) {
        guard isRunning, let handle = fileHandle else { return }
        let label = currentLabel
        let timestamp = isoFormatter.string(from: Date())
        let hex = packet.map { String(format: "%02X", $0) }.joined(separator: " ")
        let line = "\(timestamp) | \(label) | \(hex)\n"

        Task.detached(priority: .utility) { [weak self] in
            guard let data = line.data(using: .utf8) else { return }
            do {
                try handle.write(contentsOf: data)
                await MainActor.run { self?.packetCount += 1 }
            } catch {
                // Drop on error rather than crash; surface via stop on next UI poke.
                await MainActor.run { self?.stop() }
            }
        }
    }

    // MARK: - Helpers

    private static func captureDirectory() throws -> URL {
        let docs = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = docs.appendingPathComponent("Tech/MacExpert-captures", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
        }
        return dir
    }

    private static func timestampForFilename() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
}
