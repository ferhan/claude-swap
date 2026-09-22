import SwiftUI
import WidgetKit

// The two controls that act beyond the widget: "Switch to this account" and
// "Start backend". SwiftUI shapes and text only -- AppKit controls draw as the
// widget renderer's "unsupported view" placeholder.

/// A capsule with an icon and a label: the look shared by both controls.
struct ActionChip: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(.primary.opacity(0.1)))
            .overlay(Capsule().stroke(.primary.opacity(0.15), lineWidth: 1))
            .contentShape(Capsule())
    }
}

/// A state in words beside, or instead of, a control.
struct ActionNote: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }
}

/// "Start backend", or "Starting…" for the ~30s after it was clicked.
///
/// A `Link`, not a `Button(intent:)`: an intent runs in the sandboxed
/// extension, which cannot exec cswap. The link opens
/// `claudeswap://start-backend`, which LaunchServices hands to the host app
/// (unsandboxed, no Dock icon); it runs `cswap service start` and quits. This
/// is the only `Link` in the widget: every other tap stays in the extension,
/// and a tap that misses every control still only refreshes.
struct StartBackendControl: View {
    let context: PageContext
    var short = false

    var body: some View {
        if context.isBackendStarting {
            ActionNote(title: "Starting…", symbol: "hourglass")
        } else {
            Link(destination: BackendStart.url) {
                ActionChip(title: short ? "Start" : "Start backend", symbol: "play.circle")
            }
            .accessibilityLabel("Start backend")
        }
    }
}

/// The selected account's switch control: a button for an account that can
/// be switched to, "Active" for the active one, and the pending/failed state
/// of a request. With the backend stopped nothing would apply a request, so
/// the button gives way to "Start backend".
struct SwitchControl: View {
    let account: Account
    let context: PageContext

    var body: some View {
        switch account.switchEligibility(activeNumber: context.snapshot.activeAccountNumber) {
        case .active:
            ActiveMarker()
        case .notSwitchable:
            ActionNote(title: "Not switchable", symbol: "nosign")
                .accessibilityLabel("Not switchable: no stored login for this account")
        case .eligible:
            if context.isBackendStale {
                ViewThatFits(in: .horizontal) {
                    StartBackendControl(context: context)
                    StartBackendControl(context: context, short: true)
                }
            } else {
                switch context.switchState {
                case .switching(target: account.number):
                    ActionNote(title: "Switching…", symbol: "clock")
                case .notApplied(target: account.number):
                    ViewThatFits(in: .horizontal) {
                        notApplied("Switch not applied")
                        notApplied("Not applied")
                        switchButton("Retry switch", symbol: "arrow.clockwise")
                        switchButton("Retry", symbol: "arrow.clockwise")
                    }
                default:
                    ViewThatFits(in: .horizontal) {
                        switchButton("Switch to this account", symbol: "arrow.left.arrow.right")
                        switchButton("Switch", symbol: "arrow.left.arrow.right")
                    }
                }
            }
        }
    }

    private func notApplied(_ text: String) -> some View {
        HStack(spacing: 6) {
            ActionNote(title: text, symbol: "exclamationmark.circle")
            switchButton("Retry", symbol: "arrow.clockwise")
        }
    }

    private func switchButton(_ title: String, symbol: String) -> some View {
        Button(intent: SwitchAccountIntent(number: account.number)) {
            ActionChip(title: title, symbol: symbol)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Switch to \(account.label)")
    }
}
