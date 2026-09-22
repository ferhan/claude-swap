import SwiftUI
import WidgetKit

// The auto-switch control on large and extra-large, and its chip.

/// The auto-switch chip: the label, a filled state dot and the state in
/// words, on one capsule.
///
/// Everything here is drawn from `isOn`/`isDisabled` -- the resolved state --
/// and never from a `Toggle`'s own binding. WidgetKit flips that binding
/// optimistically the moment it is tapped, so a dot bound to it went green
/// beside a label still reading "Off" whenever the backend never confirmed.
///
/// SwiftUI shapes and text rather than `.toggleStyle(.switch)`: AppKit's
/// switch is not one of the controls a widget's out-of-process renderer can
/// draw, so it came out as the yellow "unsupported view" placeholder.
struct AutoswitchChip: View {
    let isOn: Bool
    /// `at 85%` / `Off` -- the state in words, so the dot is never the only
    /// thing carrying it.
    let stateText: String
    var isDisabled = false
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        HStack(spacing: 6) {
            Label("Auto-switch", systemImage: "arrow.triangle.2.circlepath")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 12, weight: .semibold))
                .fixedSize()
            Circle()
                .fill(dot)
                .frame(width: 9, height: 9)
            Text(stateText)
                .font(.system(size: 12, weight: .semibold))
                .fixedSize()
        }
        .foregroundStyle(isDisabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(.primary.opacity(isDisabled ? 0.04 : 0.1)))
        .overlay(Capsule().stroke(.primary.opacity(isDisabled ? 0.08 : 0.15), lineWidth: 1))
        .contentShape(Capsule())
        .opacity(isDisabled ? 0.7 : 1)
    }

    private var dot: Color {
        if isDisabled { return .primary.opacity(0.25) }
        guard mode == .fullColor else { return isOn ? .primary : .primary.opacity(0.35) }
        return isOn ? .green : .red
    }
}

/// Draws the chip with the resolved state, ignoring the configuration the
/// `Toggle` hands in (see `AutoswitchChip`).
struct AutoswitchChipStyle: ToggleStyle {
    let resolved: ToggleResolution
    let stateText: String

    func makeBody(configuration: Configuration) -> some View {
        AutoswitchChip(isOn: resolved.isOn, stateText: stateText)
    }
}

/// The auto-switch line: a labeled switch, its threshold, and who is next up.
/// The toggle drops a request for the backend (see `SetAutoswitchIntent`) and
/// shows the asked-for state, marked pending, until the snapshot agrees. With
/// the backend stopped the chip is inert: nothing would apply a request, and
/// the header offers "Start backend" instead.
struct AutoStatusLine: View {
    let context: PageContext

    var body: some View {
        HStack(spacing: 6) {
            if let auto = context.snapshot.autoswitch, let toggle = context.toggle {
                let stateText = toggle.isOn ? "at \(Format.pct(auto.threshold))" : "Off"
                if toggle.isDisabled {
                    AutoswitchChip(isOn: toggle.isOn, stateText: stateText, isDisabled: true)
                        .accessibilityLabel("Auto-switch \(toggle.isOn ? "on" : "off"), backend stopped")
                } else {
                    Toggle(isOn: toggle.isOn, intent: SetAutoswitchIntent(enabled: !toggle.isOn)) {
                        EmptyView()
                    }
                    .toggleStyle(AutoswitchChipStyle(resolved: toggle, stateText: stateText))
                    .fixedSize()
                    .accessibilityLabel("Auto-switch \(toggle.isOn ? "on, \(stateText)" : "off")")
                }
                if toggle.isPending {
                    Label("applying…", systemImage: "clock").labelStyle(.titleAndIcon).fixedSize()
                } else if toggle.backendNotRunning {
                    ViewThatFits(in: .horizontal) {
                        notRunning("backend not running")
                        notRunning("not running")
                    }
                } else if toggle.isOn, !toggle.isDisabled, let next = context.snapshot.nextCandidate {
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
