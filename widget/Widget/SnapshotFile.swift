import Foundation

/// The one place that decides where the snapshot document lives.
///
/// This path is a public contract between two separately installed programs:
/// the widget, shipped as a notarized .dmg, and the user's own `cswap`,
/// installed from PyPI. It is therefore an ordinary absolute path rather than
/// a shared App Group container -- a python3 process carries no code signature
/// and so no App Group entitlement, and `containermanagerd` denies an
/// unentitled writer. (The container works for the *reader*; it is the writer
/// that cannot get in, which is what rules the design out.)
///
/// `~/.claude-swap-backup/` is the directory cswap owns and already keeps
/// `settings.json`, `menubar_settings.json` and `sequence.json` in -- unlike
/// `~/.claude/`, which is Claude Code's, gets pruned by it, and moves when
/// `CLAUDE_CONFIG_DIR` is set.
///
/// **The paths are these two properties plus the two exceptions in
/// `CswapWidgetExtension.entitlements`.** Nothing else in the widget knows
/// where the snapshot or the request drop is; each must move with its
/// exception or the extension gets EPERM.
enum SnapshotFile {
    static var url: URL { home.appending(path: ".claude-swap-backup/snapshot.json") }

    /// Where the auto-switch toggle drops its request files (see
    /// `AutoswitchRequest`). The backend creates it; the widget never does.
    static var requestsDirectory: URL { home.appending(path: ".claude-swap-backup/widget-requests") }

    /// The host app's "a start was asked for" marker (see `BackendStart`).
    static var backendStartMarker: URL { requestsDirectory.appending(path: BackendStart.markerName) }

    // NSHomeDirectory() is the sandbox container, not ~; the passwd entry is
    // the real home the CLI writes into, and also the root the sandbox
    // exceptions' home-relative paths resolve against.
    static var home: URL {
        getpwuid(getuid())
            .map { URL(fileURLWithPath: String(cString: $0.pointee.pw_dir)) }
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    static func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Snapshot.decode(data)
    }

    static func loadBackendStart() -> Date? {
        (try? Data(contentsOf: backendStartMarker)).flatMap(BackendStart.markerDate)
    }
}
