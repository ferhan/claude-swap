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

enum BackendStart {
    /// The URL the Start control opens. Registered to the host app in
    /// `CFBundleURLTypes` (project.yml).
    static let url = URL(string: "claudeswap://start-backend")!

    static func isStartURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "claudeswap" && url.host?.lowercased() == "start-backend"
    }

    /// The marker's name inside the request directory.
    static let markerName = ".backend-starting"

    /// How long "Starting…" may show without a fresh snapshot.
    static let pendingTimeout: TimeInterval = 30

    static func marker(at date: Date) -> Data {
        Data(#"{"at":"\#(date.formatted(Date.ISO8601FormatStyle()))"}"#.utf8)
    }

    static func markerDate(_ data: Data) -> Date? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["at"] as? String else { return nil }
        return (try? Date.ISO8601FormatStyle().parse(text))
    }

    /// "Starting…" instead of the Start control: the snapshot is still stale
    /// (a fresh one resolves it) and the host asked less than 30s ago.
    static func isStarting(markerAt: Date?, snapshotStale: Bool, now: Date) -> Bool {
        guard snapshotStale, let markerAt else { return false }
        let age = now.timeIntervalSince(markerAt)
        // A little slack for the marker's whole-second timestamp.
        return age > -5 && age < pendingTimeout
    }

    static func expiry(markerAt: Date?, now: Date) -> Date? {
        guard let end = markerAt?.addingTimeInterval(pendingTimeout), end > now else { return nil }
        return end
    }

    /// Where cswap may be installed when the snapshot does not name it
    /// (snapshots written before `cswapCommand` existed).
    static func fallbackPaths(home: String) -> [String] {
        ["\(home)/.local/bin/cswap", "/opt/homebrew/bin/cswap", "/usr/local/bin/cswap"]
    }

    /// The argv prefix that runs cswap: the snapshot's `cswapCommand` when it
    /// names an executable, else the first executable fallback path.
    static func cswapCommand(snapshot: Data?, home: String,
                             isExecutable: (String) -> Bool) -> [String]? {
        if let snapshot,
           let object = try? JSONSerialization.jsonObject(with: snapshot) as? [String: Any],
           let command = object["cswapCommand"] as? [String],
           let executable = command.first, executable.hasPrefix("/"), isExecutable(executable) {
            return command
        }
        return fallbackPaths(home: home).first(where: isExecutable).map { [$0] }
    }
}
