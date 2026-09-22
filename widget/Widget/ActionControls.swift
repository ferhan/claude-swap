import SwiftUI
import WidgetKit

// The two controls that act beyond the widget: "Switch to this account" and
// "Start backend". SwiftUI shapes and text only -- AppKit controls draw as the
// widget renderer's "unsupported view" placeholder.

/// A capsule with an icon and a label: the look shared by both controls.
struct ActionChip: View {
    let title: String
    let symbol: String
    /// Medium's right column is 147pt: the chip drops to the small type scale
    /// there so "Switch to this account" fits whole rather than shortening.
    var compact = false

    var body: some View {
        Label(title, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.system(size: compact ? 10 : 12, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 3 : 4)
            .background(Capsule().fill(.primary.opacity(0.1)))
            .overlay(Capsule().stroke(.primary.opacity(0.15), lineWidth: 1))
            .contentShape(Capsule())
    }
}

/// A state in words beside, or instead of, a control. The symbol is optional
/// because small's bottom line is 62pt beside the pager: the glyph is what
/// gives way there, not the word.
struct ActionNote: View {
    let title: String
    var symbol: String?
    var compact = false

    var body: some View {
        Group {
            if let symbol {
                Label(title, systemImage: symbol).labelStyle(.titleAndIcon)
            } else {
                Text(title)
            }
        }
        .font(.system(size: compact ? 10 : 12, weight: .medium))
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
    var compact = false

    var body: some View {
        if context.isBackendStarting {
            ActionNote(title: "Starting…", symbol: "hourglass", compact: compact)
        } else {
            Link(destination: BackendStart.url) {
                ActionChip(title: short ? "Start" : "Start backend",
                           symbol: "play.circle.fill", compact: compact)
            }
            .accessibilityLabel("Start backend")
        }
    }
}

/// The shown account's switch control: a button for an account that can
/// be switched to, "Active" for the active one, and the pending/failed state
/// of a request.
///
/// With the backend stopped nothing would apply a request, so the control
/// gives way to "Start backend". On small and medium it gives way whatever
/// the account is, the active one included: this spot is the only place those
/// two sizes can offer a start, and the header chip large and extra-large
/// carry is what keeps the rule to the eligible account there.
///
/// Small draws it in the same spot "Active" takes, with 62pt beside the
/// pager, which is what every shortened form here is for.
struct SwitchControl: View {
    let account: Account
    let context: PageContext
    /// Small and medium: the small type scale (see `ActionChip`).
    var compact = false

    var body: some View {
        let eligibility = account.switchEligibility(activeNumber: context.snapshot.activeAccountNumber)
        if context.isBackendStale && (compact || eligibility == .eligible) {
            ViewThatFits(in: .horizontal) {
                StartBackendControl(context: context, compact: compact)
                StartBackendControl(context: context, short: true, compact: compact)
            }
        } else {
            switch eligibility {
            case .active:
                ActiveMarker()
            case .notSwitchable:
                ViewThatFits(in: .horizontal) {
                    ActionNote(title: "Not switchable", symbol: "nosign", compact: compact)
                    ActionNote(title: "No login", symbol: "nosign", compact: compact)
                }
                .accessibilityLabel("Not switchable: no stored login for this account")
            case .eligible:
                switch context.switchState {
                case .switching(target: account.number):
                    ViewThatFits(in: .horizontal) {
                        ActionNote(title: "Switching…", symbol: "clock", compact: compact)
                        ActionNote(title: "Switching…", compact: compact)
                    }
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
            ActionNote(title: text, symbol: "exclamationmark.circle", compact: compact)
            switchButton("Retry", symbol: "arrow.clockwise")
        }
    }

    private func switchButton(_ title: String, symbol: String) -> some View {
        Button(intent: SwitchAccountIntent(number: account.number)) {
            ActionChip(title: title, symbol: symbol, compact: compact)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Switch to \(account.label)")
    }
}
