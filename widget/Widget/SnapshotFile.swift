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
/// **The path is this one property plus the read exception in
/// `CswapWidgetExtension.entitlements`.** Nothing else in the widget knows
/// where the snapshot is; the two must move together or the extension gets
/// EPERM.
enum SnapshotFile {
    static var url: URL {
        // NSHomeDirectory() is the sandbox container, not ~; the passwd entry
        // is the real home the CLI writes into, and also the root the sandbox
        // exception's home-relative path resolves against.
        let home = getpwuid(getuid())
            .map { URL(fileURLWithPath: String(cString: $0.pointee.pw_dir)) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appending(path: ".claude-swap-backup/snapshot.json")
    }

    static func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Snapshot.decode(data)
    }
}
