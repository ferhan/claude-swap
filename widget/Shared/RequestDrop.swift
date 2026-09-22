import Foundation

/// Atomic writes into `~/.claude-swap-backup/widget-requests/`: a dot-temp,
/// then a rename, mode 0600. The backend ignores dotfiles (they are in-flight
/// temps) and applies, then deletes, every other file there, so it never reads
/// half a request.
enum RequestDrop {
    enum WriteError: Error, Equatable {
        /// The backend creates the drop directory; without it nothing would
        /// read the request.
        case noDropDirectory
    }

    static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1_000).rounded(.down)) }

    /// Writes `data` as `directory/name` via `directory/.<name>.tmp`. Never
    /// creates the directory: its absence means no backend to apply it.
    @discardableResult
    static func write(_ data: Data, name: String, into directory: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw WriteError.noDropDirectory }
        let stem = name.hasPrefix(".") ? String(name.dropFirst()) : name
        let temp = directory.appending(path: ".\(stem.split(separator: ".").first ?? "request").tmp")
        let final = directory.appending(path: name)
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
