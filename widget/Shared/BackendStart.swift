import Foundation

// "Backend stopped · Start backend", minus the drawing. Shared by the widget
// extension (which draws "Starting…") and the host app (which runs
// `cswap service start`). Pure Foundation, so the test target exercises it.
//
// A widget cannot run a process, and its tap on the Start control opens a URL
// rather than running an intent, so the extension never learns of the click.
// The host app records it instead: before running cswap it drops
// `.backend-starting` into the request directory -- a dotfile, which the
// backend leaves alone -- and the extension, which may read that directory,
// shows "Starting…" while the marker is young and the snapshot still stale.
// A start that fails leaves `.backend-start-failed` the same way, and the
// widget draws "Start failed · Retry": the host app never opens a window, so
// the widget is the only place the outcome can be told.

enum BackendStart {
    /// The URL the Start control opens. Registered to the host app in
    /// `CFBundleURLTypes` (project.yml).
    static let url = URL(string: "claudeswap://start-backend")!

    static func isStartURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "claudeswap" && url.host?.lowercased() == "start-backend"
    }

    /// The marker's name inside the request directory.
    static let markerName = ".backend-starting"
    /// The failed-start marker's name, beside it.
    static let failureName = ".backend-start-failed"
    /// The host app's own log, beside them: the only record of a start, since
    /// the host has no window to say anything in.
    static let hostLogName = ".host.log"

    /// How long "Starting…" may show without a fresh snapshot. The host
    /// removes its marker either way, so this only bounds a marker left by a
    /// host that died mid-start.
    static let pendingTimeout: TimeInterval = 30
    /// How long "Start failed" stays up before the control offers a plain
    /// start again. Long enough to survive a couple of widget reloads.
    static let failureShownFor: TimeInterval = 180

    static func marker(at date: Date) -> Data {
        Data(#"{"at":"\#(date.formatted(Date.ISO8601FormatStyle()))"}"#.utf8)
    }

    static func markerDate(_ data: Data) -> Date? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["at"] as? String else { return nil }
        return (try? Date.ISO8601FormatStyle().parse(text))
    }

    /// A start that failed: when, and why in one line for VoiceOver.
    struct FailureNote: Equatable, Sendable {
        var failedAt: Date
        var reason: String
    }

    static func failureMarker(_ note: FailureNote) -> Data {
        let object: [String: String] = ["at": note.failedAt.formatted(Date.ISO8601FormatStyle()),
                                        "reason": note.reason]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    static func failureNote(_ data: Data) -> FailureNote? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["at"] as? String,
              let failedAt = try? Date.ISO8601FormatStyle().parse(text) else { return nil }
        return FailureNote(failedAt: failedAt, reason: (object["reason"] as? String) ?? "")
    }

    /// What the Start control draws.
    enum StartState: Equatable, Sendable {
        case idle
        case starting
        case failed(reason: String)
    }

    /// A fresh snapshot resolves everything: the backend is up, so neither
    /// marker matters. Otherwise a young start marker wins over a failure --
    /// a retry is under way -- and both age out, so a marker left behind can
    /// never wedge the control.
    static func state(markerAt: Date?, failure: FailureNote?, snapshotStale: Bool, now: Date) -> StartState {
        guard snapshotStale else { return .idle }
        if isStarting(markerAt: markerAt, snapshotStale: true, now: now) { return .starting }
        if let failure, isFresh(failure.failedAt, within: failureShownFor, now: now) {
            return .failed(reason: failure.reason)
        }
        return .idle
    }

    /// "Starting…" instead of the Start control: the snapshot is still stale
    /// (a fresh one resolves it) and the host asked less than 30s ago.
    static func isStarting(markerAt: Date?, snapshotStale: Bool, now: Date) -> Bool {
        guard snapshotStale, let markerAt else { return false }
        return isFresh(markerAt, within: pendingTimeout, now: now)
    }

    /// When the drawn state next changes without a new snapshot.
    static func expiry(markerAt: Date?, failure: FailureNote? = nil, now: Date) -> Date? {
        let marks = [markerAt?.addingTimeInterval(pendingTimeout),
                     failure?.failedAt.addingTimeInterval(failureShownFor)]
        return marks.compactMap { $0 }.filter { $0 > now }.min()
    }

    // A little slack for a marker's whole-second timestamp.
    private static func isFresh(_ date: Date, within window: TimeInterval, now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return age > -5 && age < window
    }

    /// Where cswap may be installed when the snapshot does not name it
    /// (snapshots written before `cswapCommand` existed).
    static func fallbackPaths(home: String) -> [String] {
        ["\(home)/.local/bin/cswap", "/opt/homebrew/bin/cswap", "/usr/local/bin/cswap"]
    }

    /// Whether the host app may exec what the snapshot names.
    ///
    /// The snapshot is the user's own 0600 file, so a doctored `cswapCommand`
    /// already needs code running as them. What it would buy is the host's
    /// identity: an unsandboxed, notarized app's child inherits its TCC and
    /// responsible-process standing, and the user starts it by tapping a
    /// legitimate Start control. So only the two shapes
    /// `launch_agent.resolve_program()` ever writes are accepted -- an
    /// absolute `cswap`, or an interpreter running `-m claude_swap` -- and
    /// only when nobody but the owner can rewrite the file.
    static func isAcceptableCommand(_ command: [String], mode: (String) -> Int?) -> Bool {
        guard let executable = command.first, executable.hasPrefix("/") else { return false }
        let arguments = Array(command.dropFirst())
        guard (executable as NSString).lastPathComponent == "cswap" || arguments == ["-m", "claude_swap"] else {
            return false
        }
        guard let bits = mode(executable), bits & 0o022 == 0 else { return false }
        return true
    }

    /// The file's permission bits, or nil when they cannot be read.
    static func fileMode(_ path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int
    }

    /// The argv prefix that runs cswap: the snapshot's `cswapCommand` when it
    /// names an acceptable executable, else the first executable fallback
    /// path.
    static func cswapCommand(snapshot: Data?, home: String,
                             isExecutable: (String) -> Bool,
                             mode: (String) -> Int? = fileMode) -> [String]? {
        if let snapshot,
           let object = try? JSONSerialization.jsonObject(with: snapshot) as? [String: Any],
           let command = object["cswapCommand"] as? [String],
           isAcceptableCommand(command, mode: mode),
           isExecutable(command[0]) {
            return command
        }
        return fallbackPaths(home: home).first(where: isExecutable).map { [$0] }
    }
}
