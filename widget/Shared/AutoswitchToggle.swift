import Foundation

// The auto-switch toggle, minus the drawing: the request file the widget drops
// for the backend, and how a pending request resolves against the snapshot.
// Pure Foundation, so the test target exercises it directly.

/// A request to turn auto-switch on or off, dropped as a file into
/// `~/.claude-swap-backup/widget-requests/`. The backend applies the newest one
/// and republishes the snapshot; the widget never writes `settings.json`.
///
/// Contract: the file is `autoswitch-<epochMillis>.json`, written as
/// `.autoswitch-<epochMillis>.tmp` then renamed, so the backend never reads
/// half a file. Content: `{"autoswitch": {"enabled": true}, "at": "<ISO8601>"}`.
struct AutoswitchRequest: Encodable, Equatable, Sendable {
    struct Body: Encodable, Equatable, Sendable { let enabled: Bool }

    let autoswitch: Body
    let requestedAt: String

    private enum CodingKeys: String, CodingKey {
        case autoswitch, requestedAt = "at"
    }

    init(enabled: Bool, at date: Date) {
        autoswitch = Body(enabled: enabled)
        requestedAt = date.formatted(Date.ISO8601FormatStyle())
    }

    static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1_000).rounded(.down)) }
    static func fileName(at date: Date) -> String { "autoswitch-\(millis(date)).json" }
    static func tempName(at date: Date) -> String { ".autoswitch-\(millis(date)).tmp" }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }

    enum WriteError: Error, Equatable {
        /// The backend creates the drop directory; without it nothing would
        /// read the request.
        case noDropDirectory
    }

    /// Writes the request into `directory` atomically and returns its URL.
    /// Never creates the directory: its absence means no backend to apply it.
    @discardableResult
    static func write(enabled: Bool, at date: Date, into directory: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw WriteError.noDropDirectory }
        let temp = directory.appending(path: tempName(at: date))
        let final = directory.appending(path: fileName(at: date))
        let data = try AutoswitchRequest(enabled: enabled, at: date).encoded()
        guard FileManager.default.createFile(atPath: temp.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temp.path, final.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return final
    }
}

/// What the widget remembers after a toggle tap, in its own defaults, until
/// the snapshot catches up.
struct PendingToggle: Codable, Equatable, Sendable {
    /// The value the user asked for.
    var desired: Bool
    var requestedAt: Date
    /// False when the request file could not be written: nothing was flipped.
    var delivered: Bool
}

/// How the toggle is drawn right now.
struct ToggleResolution: Equatable, Sendable {
    var isOn: Bool
    /// A request is out and the snapshot has not agreed yet.
    var isPending: Bool
    /// Show "backend not running" beside the toggle.
    var backendNotRunning: Bool
}

enum AutoswitchToggle {
    /// How long a request may stay unconfirmed before the widget gives up on
    /// it and shows the snapshot's value again.
    static let pendingTimeout: TimeInterval = 30

    /// - Parameters:
    ///   - snapshotEnabled: `autoswitch.enabled` as published.
    ///   - snapshotStale: the snapshot is old enough that the backend is
    ///     presumed down (see `Snapshot.isBackendStale`).
    static func resolve(snapshotEnabled: Bool, snapshotStale: Bool,
                        pending: PendingToggle?, now: Date) -> ToggleResolution {
        let settled = ToggleResolution(isOn: snapshotEnabled, isPending: false, backendNotRunning: false)
        guard let pending else { return settled }
        let age = now.timeIntervalSince(pending.requestedAt)
        guard pending.delivered else {
            // The write failed: never flipped. Say why for as long as a
            // pending request would have lasted.
            return ToggleResolution(isOn: snapshotEnabled, isPending: false,
                                    backendNotRunning: age < pendingTimeout)
        }
        if pending.desired == snapshotEnabled { return settled }
        if age < pendingTimeout {
            return ToggleResolution(isOn: pending.desired, isPending: true, backendNotRunning: false)
        }
        // Gave up: the snapshot's value wins, and a stale snapshot is why.
        return ToggleResolution(isOn: snapshotEnabled, isPending: false, backendNotRunning: snapshotStale)
    }

    /// When the drawn state next changes without a new snapshot: the moment a
    /// live request times out. Nil when nothing is waiting.
    static func expiry(of pending: PendingToggle?, now: Date) -> Date? {
        guard let pending else { return nil }
        let end = pending.requestedAt.addingTimeInterval(pendingTimeout)
        return end > now ? end : nil
    }
}
