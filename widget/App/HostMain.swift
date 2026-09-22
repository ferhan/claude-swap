import AppKit
import os
import WidgetKit

/// Entry point. **This app has no user interface at all** -- no window, no
/// menu, no alert, no Dock icon (`LSUIElement`). It exists to be the bundle
/// the widget extension ships inside and to run `cswap service start` when
/// the widget asks. Every launch either answers a question and exits or does
/// its work and quits; none of them can draw anything.
///
/// That is deliberate, not an omission. A tap on a widget region that carries
/// no control falls through to LaunchServices as a plain launch of this app,
/// and a widget must never answer a tap with a window. There is nothing to
/// put in one either: accounts, usage, settings and the auto-switch engine
/// all live in the `cswap` CLI/TUI and the menu bar.
///
/// Three ways in:
///
/// - `--placed-widgets`: answers one question for the backend and exits
///   without ever creating an NSApplication.
/// - `claudeswap://start-backend` (the widget's Start control): runs
///   `cswap service start` and quits. The outcome goes into the markers
///   `BackendStart` defines -- the widget draws "Start failed · Retry" from
///   them -- and the detail into `.host.log` beside them.
/// - Anything else (a stray widget tap, Finder, `open -a`, an unknown URL):
///   a line in `.host.log`, then quit.
@main
enum HostMain {
    static func main() {
        if CommandLine.arguments.dropFirst().contains("--placed-widgets") {
            PlacedWidgets.run()
        }
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = HostDelegate()
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}

@MainActor
final class HostDelegate: NSObject, NSApplicationDelegate {
    /// How long a launch that says it is plain waits for a URL before it
    /// gives up and quits.
    ///
    /// `launchIsDefaultUserInfoKey` is missing on a cold URL launch, which
    /// reads as "plain", and the URL event can arrive after
    /// `applicationDidFinishLaunching` anyway. Quitting at that moment would
    /// kill a Start tap before its URL was delivered.
    private static let urlGrace: TimeInterval = 1

    private var starting = false
    private var handledURL = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let plainLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        let arguments = CommandLine.arguments.dropFirst().joined(separator: " ")
        HostLog.write("launch: plainLaunch=\(plainLaunch) args=[\(arguments)]")
        guard plainLaunch else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.urlGrace) { [weak self] in
            guard let self, !self.handledURL, !self.starting else { return }
            // Nothing asked for anything: a stray widget tap, or someone
            // opening the app to see what it is. There is no window to show
            // them, so go away again rather than sit in the process list.
            HostLog.write("plain launch: nothing to do, quitting")
            NSApp.terminate(nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handledURL = true
        guard urls.contains(where: BackendStart.isStartURL) else {
            HostLog.write("url ignored: \(urls.map(\.absoluteString).joined(separator: " "))")
            NSApp.terminate(nil)
            return
        }
        HostLog.write("url: start-backend")
        startBackend()
    }

    private func startBackend() {
        guard !starting else { return }
        starting = true
        Task.detached {
            let result = BackendStarter.run()
            await MainActor.run { self.finish(result) }
        }
    }

    private func finish(_ result: Result<Void, BackendStarter.Failure>) {
        starting = false
        // No alert, ever: a tap on a widget must not summon a window. The
        // widget draws "Start failed · Retry" from the marker the starter
        // left, and this reload is what makes it do so.
        WidgetCenter.shared.reloadAllTimelines()
        NSApp.terminate(nil)
    }
}

/// The host app's log: a line per launch, appended to `.host.log` in the
/// request directory and mirrored to `os_log` (subsystem `com.cswap.widget`).
/// The app has no window on the Start path, so without this a start that goes
/// wrong leaves nothing behind to read.
enum HostLog {
    private static let logger = Logger(subsystem: "com.cswap.widget", category: "host")
    /// Trimmed to the last 200 lines once it passes this.
    private static let maxBytes = 64 * 1024

    static func write(_ message: String) {
        logger.log("\(message, privacy: .public)")
        let line = "\(Date().formatted(Date.ISO8601FormatStyle())) [\(getpid())] \(message)\n"
        let url = SnapshotFile.requestsDirectory.appending(path: BackendStart.hostLogName)
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // 0600 like everything else the widget drops here.
            FileManager.default.createFile(atPath: url.path, contents: data,
                                           attributes: [.posixPermissions: 0o600])
        }
        trim(url)
    }

    private static func trim(_ url: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > maxBytes,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let tail = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(200)
        _ = try? RequestDrop.write(Data(tail.joined(separator: "\n").utf8), name: BackendStart.hostLogName,
                                   into: url.deletingLastPathComponent())
    }
}

/// Runs `cswap service start`. Blocking; call off the main thread.
enum BackendStarter {
    struct Failure: Error {
        let message: String
    }

    static let timeout: TimeInterval = 20

    static func run() -> Result<Void, Failure> {
        let fileManager = FileManager.default
        let marker = SnapshotFile.backendStartMarker
        let failureMarker = SnapshotFile.backendFailureMarker
        // The marker tells the widget a start is under way ("Starting…"). The
        // backend normally creates the request directory; before its first
        // run there is none, so make it the way the backend does (0700).
        try? fileManager.createDirectory(at: SnapshotFile.requestsDirectory, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
        let startedAt = Date()
        _ = try? RequestDrop.write(BackendStart.marker(at: startedAt), name: BackendStart.markerName,
                                   into: SnapshotFile.requestsDirectory)
        // Whatever an earlier attempt left: this one supersedes it.
        try? fileManager.removeItem(at: failureMarker)
        WidgetCenter.shared.reloadAllTimelines()

        let result = execute()
        switch result {
        case .failure(let failure):
            HostLog.write("start failed after \(elapsed(since: startedAt)): \(failure.message)")
            _ = try? RequestDrop.write(
                BackendStart.failureMarker(.init(failedAt: Date(), reason: failure.message)),
                name: BackendStart.failureName, into: SnapshotFile.requestsDirectory)
        case .success:
            // The caller reloads the widget next. Give the backend a few
            // seconds to publish, so that reload draws the fresh snapshot.
            var published = false
            for _ in 0..<10 {
                if let taken = SnapshotFile.load()?.takenAt, taken > startedAt.addingTimeInterval(-1) {
                    published = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
            HostLog.write("start ok after \(elapsed(since: startedAt))"
                          + (published ? ", snapshot published" : ", no fresh snapshot yet"))
        }
        // Either way the start is over: a marker left behind would only keep
        // the widget on "Starting…" until it aged out.
        try? fileManager.removeItem(at: marker)
        return result
    }

    private static func elapsed(since start: Date) -> String {
        String(format: "%.1fs", Date().timeIntervalSince(start))
    }

    private static func execute() -> Result<Void, Failure> {
        let home = SnapshotFile.home.path
        guard let command = BackendStart.cswapCommand(
            snapshot: try? Data(contentsOf: SnapshotFile.url), home: home,
            isExecutable: FileManager.default.isExecutableFile(atPath:)) else {
            let paths = BackendStart.fallbackPaths(home: home).joined(separator: ", ")
            return .failure(Failure(message: "cswap was not found. The snapshot names no cswapCommand, and "
                                    + "there is no cswap in \(paths)."))
        }

        // Output to a file, not a pipe: if cswap leaves a child holding the
        // descriptor, reading a pipe to its end would never return.
        let log = FileManager.default.temporaryDirectory.appending(path: "claudeswap-start-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        guard let output = try? FileHandle(forWritingTo: log) else {
            return .failure(Failure(message: "Could not create a log file for cswap's output."))
        }
        defer { try? output.close() }

        HostLog.write("running \((command + ["service", "start"]).joined(separator: " "))")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst()) + ["service", "start"]
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        // A LaunchServices launch gets launchd's bare PATH, not the login
        // shell's; cswap and whatever it runs expect the usual places.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                               environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
        process.environment = environment

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            return .failure(Failure(message: "Could not run \(command[0]): \(error.localizedDescription)"))
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return .failure(Failure(message: "`cswap service start` did not finish within \(Int(timeout))s."))
        }
        guard process.terminationStatus == 0 else {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            let tail = text.split(separator: "\n").suffix(6).joined(separator: "\n")
            return .failure(Failure(message: "`cswap service start` exited with status "
                                    + "\(process.terminationStatus).\(tail.isEmpty ? "" : "\n\n\(tail)")"))
        }
        return .success(())
    }
}

/// `ClaudeSwap --placed-widgets` prints `{"count": N}` -- how many ClaudeSwap
/// widgets are on the desktop -- and exits 0. The backend treats a placed
/// widget as an open surface. On failure: a message on stderr, non-zero exit.
enum PlacedWidgets {
    static let timeout: TimeInterval = 10

    static func run() -> Never {
        WidgetCenter.shared.getCurrentConfigurations { result in
            switch result {
            case .success(let configurations):
                print("{\"count\": \(configurations.count)}")
                exit(0)
            case .failure(let error):
                fail("getCurrentConfigurations failed: \(error)")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            fail("getCurrentConfigurations did not answer within \(Int(timeout))s")
        }
        dispatchMain()
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("ClaudeSwap --placed-widgets: \(message)\n".utf8))
        exit(1)
    }
}
