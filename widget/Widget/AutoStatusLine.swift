import SwiftUI
import WidgetKit

// The auto-switch control on large and extra-large, and its chip style.

/// The auto-switch chip's look: the label, a filled state dot and the state
/// in words, on one tappable capsule.
///
/// A custom style rather than `.toggleStyle(.switch)`: AppKit's switch is not
/// one of the controls a widget's out-of-process renderer can draw, so it came
/// out as the yellow "unsupported view" placeholder. Everything here is
/// SwiftUI shapes and text, which always draw.
struct AutoswitchChipStyle: ToggleStyle {
    /// `at 85%` / `Off` -- the state in words, so the dot is never the only
    /// thing carrying it.
    let stateText: String
    @Environment(\.widgetRenderingMode) private var mode

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.label
            Circle()
                .fill(dot(isOn: configuration.isOn))
                .frame(width: 9, height: 9)
            Text(stateText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(.primary.opacity(0.1)))
        .overlay(Capsule().stroke(.primary.opacity(0.15), lineWidth: 1))
        .contentShape(Capsule())
    }

    private func dot(isOn: Bool) -> Color {
        guard mode == .fullColor else { return isOn ? .primary : .primary.opacity(0.35) }
        return isOn ? .green : .red
    }
}

/// The auto-switch line: a labeled switch, its threshold, and who is next up.
/// The toggle drops a request for the backend (see `SetAutoswitchIntent`) and
/// shows the asked-for state, marked pending, until the snapshot agrees.
struct AutoStatusLine: View {
    let context: PageContext

    var body: some View {
        HStack(spacing: 6) {
            if let auto = context.snapshot.autoswitch, let toggle = context.toggle {
                Toggle(isOn: toggle.isOn, intent: SetAutoswitchIntent(enabled: !toggle.isOn)) {
                    Label("Auto-switch", systemImage: "arrow.triangle.2.circlepath")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .fixedSize()
                }
                .toggleStyle(AutoswitchChipStyle(
                    stateText: toggle.isOn ? "at \(Format.pct(auto.threshold))" : "Off"))
                .fixedSize()
                .accessibilityLabel("Auto-switch \(toggle.isOn ? "on, at \(Format.pct(auto.threshold))" : "off")")
                if toggle.isPending {
                    Label("applying…", systemImage: "clock").labelStyle(.titleAndIcon).fixedSize()
                } else if toggle.backendNotRunning && !context.isBackendStale {
                    // A stale snapshot already says so in the header.
                    ViewThatFits(in: .horizontal) {
                        notRunning("backend not running")
                        notRunning("not running")
                    }
                } else if toggle.isOn, let next = context.snapshot.nextCandidate {
                    // The "(12% used)" goes first, then the name; the badge
                    // stays rather than showing a stub of the name.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 5) {
                            nextUp(next)
                            nextTitle(next).fixedSize()
                            if let peak = next.peakPct { Text("(\(Format.pct(peak)) used)").fixedSize() }
                        }
                        HStack(spacing: 5) {
                            nextUp(next)
                            nextTitle(next).fixedSize()
                        }
                        nextUp(next)
                    }
                }
            } else {
                Image(systemName: "questionmark.circle")
                Text("Auto-switch status unavailable · threshold \(Format.pct(Display.defaultThreshold))")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(minHeight: 24)
    }

    private func notRunning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle")
            .labelStyle(.titleAndIcon)
            .fixedSize()
    }

    private func nextUp(_ account: Account) -> some View {
        HStack(spacing: 5) {
            Text("· next").fixedSize()
            InitialsBadge(account: account, size: 20)
        }
    }

    private func nextTitle(_ account: Account) -> some View {
        AccountTitle(account: account, font: .system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
    }
}
