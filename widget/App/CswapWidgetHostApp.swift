import SwiftUI

/// Container for the widget extension, and nothing else.
///
/// A WidgetKit extension cannot be installed on its own, so it ships inside an
/// app. This is that app. Account switching, usage, settings and the live
/// auto-switch engine all live in the `cswap` CLI/TUI and the menu bar; none
/// of it is reimplemented here.
@main
struct CswapWidgetHostApp: App {
    var body: some Scene {
        Window("cswap Widget", id: "main") {
            VStack(spacing: 12) {
                Text("cswap Widget")
                    .font(.title2.weight(.semibold))
                Text("This app only installs the cswap widget. Add it from the "
                     + "desktop widget gallery.")
                Text("Use the `cswap` command line tool or the menu bar for "
                     + "everything else.")
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .frame(width: 380)
            .padding(32)
        }
        .windowResizability(.contentSize)
    }
}
