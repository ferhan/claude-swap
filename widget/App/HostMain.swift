import AppKit
import WidgetKit

/// Entry point. Three ways in:
///
/// - `--placed-widgets`: answers one question for the backend and exits
///   without ever creating an NSApplication.
/// - `claudeswap://start-backend` (the widget's Start control): runs
///   `cswap service start` and quits. No window; `LSUIElement` means no Dock
///   icon either.
/// - A plain launch (Finder, `open -a`): the info window, with a Dock icon for
///   as long as it is open.
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
    private var window: NSWindow?
    private var starting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // False when LaunchServices launched us to open a URL. The URL itself
        // may arrive just before or just after this call.
        let plainLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        if plainLaunch && !starting { showInfoWindow() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: BackendStart.isStartURL) {
            startBackend()
        } else {
            showInfoWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func showInfoWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = InfoWindow.mainMenu()
        let window = self.window ?? InfoWindow.make()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
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
        WidgetCenter.shared.reloadAllTimelines()
        if case .failure(let failure) = result {
            // An alert, not a notification: a notification needs the user to
            // have granted permission first -- the request would itself be the
            // first thing they see -- and can be silenced. A failed start is
            // rare and needs acting on.
            NSApp.activate()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "ClaudeSwap could not start the backend"
            alert.informativeText = failure.message
                + "\n\nRun `cswap service start` in a terminal for details."
            alert.runModal()
        }
        if window == nil { NSApp.terminate(nil) }
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
        // The marker tells the widget a start is under way ("Starting…"). The
        // backend normally creates the request directory; before its first
        // run there is none, so make it the way the backend does (0700).
        try? fileManager.createDirectory(at: SnapshotFile.requestsDirectory, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
        let startedAt = Date()
        _ = try? RequestDrop.write(BackendStart.marker(at: startedAt), name: BackendStart.markerName,
                                   into: SnapshotFile.requestsDirectory)
        WidgetCenter.shared.reloadAllTimelines()

        let result = execute()
        switch result {
        case .failure:
            try? fileManager.removeItem(at: marker)
        case .success:
            // The caller reloads the widget next. Give the backend a few
            // seconds to publish, so that reload draws the fresh snapshot.
            for _ in 0..<10 {
                if let taken = SnapshotFile.load()?.takenAt, taken > startedAt.addingTimeInterval(-1) { break }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        return result
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
