import AppKit
import WidgetKit

/// Entry point. A normal launch shows the stub window; `--placed-widgets`
/// answers one question for the backend and exits without ever creating an
/// NSApplication, so there is no window and no Dock icon.
@main
enum HostMain {
    static func main() {
        if CommandLine.arguments.dropFirst().contains("--placed-widgets") {
            PlacedWidgets.run()
        }
        CswapWidgetHostApp.main()
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
