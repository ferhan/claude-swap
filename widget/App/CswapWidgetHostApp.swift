import AppKit
import SwiftUI

/// Container for the widget extension, and nothing else.
///
/// A WidgetKit extension cannot be installed on its own, so it ships inside an
/// app. This is that app. Account switching, usage, settings and the live
/// auto-switch engine all live in the `cswap` CLI/TUI and the menu bar; none
/// of it is reimplemented here.
///
/// AppKit rather than a SwiftUI `App`: a SwiftUI `Window` scene opens at every
/// launch, and a launch to handle `claudeswap://start-backend` must show
/// nothing. `HostDelegate` shows this window only for a plain launch.
enum InfoWindow {
    @MainActor static func make() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: InfoView()))
        window.title = "ClaudeSwap"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    /// Cmd-Q and Cmd-W; the app has no other commands.
    @MainActor static func mainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit ClaudeSwap", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        let item = NSMenuItem()
        item.submenu = appMenu
        let menu = NSMenu()
        menu.addItem(item)
        return menu
    }
}

private struct InfoView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("ClaudeSwap Widget")
                .font(.title2.weight(.semibold))
            Text("This app only installs the ClaudeSwap widget. Add it from the "
                 + "desktop widget gallery.")
            Text("Use the `cswap` command line tool or the menu bar for "
                 + "everything else.")
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(width: 380)
        .padding(32)
    }
}
