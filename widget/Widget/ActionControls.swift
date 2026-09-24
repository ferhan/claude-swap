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
    /// Large's account card: 11pt and a slimmer capsule, the height of the
    /// "Details ›" beside it, so three cards still fit.
    var dense = false

    var body: some View {
        Label(title, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.system(size: compact ? 10 : dense ? 11 : 12, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact || dense ? 3 : 4)
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
        switch context.startState {
        case .starting:
            ActionNote(title: "Starting…", symbol: "hourglass", compact: compact)
        case .failed(let reason):
            // The host app has no window to report in: this is where a failed
            // start is told, with the reason riding along for VoiceOver.
            ViewThatFits(in: .horizontal) {
                failed("Start failed")
                failed("Failed")
                // Small's 62pt: the chip's own symbol carries the failure.
                startLink(title: "Retry", symbol: "exclamationmark.arrow.circlepath")
            }
            .accessibilityLabel("Start failed: \(reason.isEmpty ? "unknown error" : reason). Retry.")
        case .idle:
            startLink(title: short ? "Start" : "Start backend", symbol: "play.circle.fill")
                .accessibilityLabel("Start backend")
        }
    }

    private func failed(_ text: String) -> some View {
        HStack(spacing: 6) {
            ActionNote(title: text, symbol: "exclamationmark.circle", compact: compact)
            startLink(title: "Retry", symbol: "arrow.clockwise")
        }
    }

    private func startLink(title: String, symbol: String) -> some View {
        Link(destination: BackendStart.url) {
            ActionChip(title: title, symbol: symbol, compact: compact)
        }
    }
}

/// Small's bottom line, beside the ‹ ›: one spot that carries the start
/// control, the auto-switch toggle or the switch control, whichever the state
/// calls for (`CompactSlot` decides). Small has 62pt of it, which is what
/// every shortened form in this file is for. Medium draws both controls.
struct CompactActionControl: View {
    let account: Account
    let context: PageContext

    var body: some View {
        let action = CompactSlot.resolve(
            family: context.family,
            eligibility: account.switchEligibility(activeNumber: context.snapshot.activeAccountNumber),
            backendStale: context.isBackendStale,
            hasAutoswitch: context.snapshot.autoswitch != nil)
        switch action {
        case .start:
            ViewThatFits(in: .horizontal) {
                StartBackendControl(context: context, compact: true)
                StartBackendControl(context: context, short: true, compact: true)
            }
        case .auto:
            CompactAutoControl(context: context)
        case .switchAccount:
            SwitchControl(account: account, context: context, compact: true)
        }
    }
}

/// The shown account's switch control: a button for an account that can
/// be switched to, "Active" for the active one, and the pending/failed state
/// of a request.
///
/// With the backend stopped nothing would apply a request, so for an eligible
/// account the control gives way to "Start backend". Small and medium never
/// reach that branch: `CompactActionControl` has already decided what a
/// stopped backend puts in their one spot.
struct SwitchControl: View {
    let account: Account
    let context: PageContext
    /// Small and medium: the small type scale (see `ActionChip`).
    var compact = false
    /// Large's account card: the short labels only -- "Switch", not "Switch
    /// to this account" -- at the full type scale.
    var short = false

    var body: some View {
        let eligibility = account.switchEligibility(activeNumber: context.snapshot.activeAccountNumber)
        if context.isBackendStale && eligibility == .eligible {
            ViewThatFits(in: .horizontal) {
                if !short { StartBackendControl(context: context, compact: compact) }
                StartBackendControl(context: context, short: true, compact: compact)
            }
        } else {
            switch eligibility {
            case .active:
                ActiveMarker()
            case .notSwitchable:
                ViewThatFits(in: .horizontal) {
                    if !short { ActionNote(title: "Not switchable", symbol: "nosign", compact: compact) }
                    ActionNote(title: "No login", symbol: "nosign", compact: compact)
                }
                .accessibilityLabel("Not switchable: no stored login for this account")
            case .disabled:
                ViewThatFits(in: .horizontal) {
                    ActionNote(title: "Disabled", symbol: "nosign", compact: compact)
                    ActionNote(title: "Disabled", compact: compact)
                }
                .accessibilityLabel("Disabled: this account cannot be switched to from the widget")
            case .eligible:
                switch context.switchState {
                case .switching(target: account.number):
                    ViewThatFits(in: .horizontal) {
                        ActionNote(title: "Switching…", symbol: "clock", compact: compact)
                        ActionNote(title: "Switching…", compact: compact)
                    }
                case .notApplied(target: account.number):
                    ViewThatFits(in: .horizontal) {
                        if !short { notApplied("Switch not applied") }
                        notApplied("Not applied")
                        switchButton("Retry switch", symbol: "arrow.clockwise")
                        switchButton("Retry", symbol: "arrow.clockwise")
                    }
                default:
                    ViewThatFits(in: .horizontal) {
                        if !short {
                            switchButton("Switch to this account", symbol: "arrow.left.arrow.right")
                        }
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
            ActionChip(title: title, symbol: symbol, compact: compact, dense: short)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Switch to \(account.label)")
    }
}
