import SwiftUI
import WidgetKit

// The auto-switch control on large and extra-large, and its chip.

/// The auto-switch chip: the label, a filled state dot and the state in
/// words, on one capsule.
///
/// The dot and the words both come from `isOn` -- one value, so they cannot
/// disagree. That is the whole rule here. An earlier version bound only the
/// dot to the `Toggle`'s own binding, which WidgetKit flips optimistically
/// the moment it is tapped, and left the words on the resolved state: the dot
/// went green beside a label still reading "Off". The answer is to feed both
/// from the same value, not to throw the optimistic flip away -- it is the
/// only feedback available in the second or so before a reload can land.
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
    /// Small and medium's action spot, where the whole chip has ~62pt: the
    /// words "Auto-switch" give way to the glyph alone, and the type drops to
    /// the compact scale the switch chip beside it already uses.
    var compact = false
    /// The glyph, which is also where a compact chip carries a pending or
    /// undelivered request -- there is no room for those in words.
    var symbol = "arrow.triangle.2.circlepath"
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        let size: CGFloat = compact ? 10 : 12
        HStack(spacing: compact ? 4 : 6) {
            Group {
                if compact {
                    Image(systemName: symbol)
                } else {
                    Label("Auto-switch", systemImage: symbol).labelStyle(.titleAndIcon)
                }
            }
            .font(.system(size: size, weight: .semibold))
            .fixedSize()
            Circle()
                .fill(dot)
                .frame(width: compact ? 7 : 9, height: compact ? 7 : 9)
            Text(stateText)
                .font(.system(size: size, weight: .semibold))
                .fixedSize()
        }
        .foregroundStyle(isDisabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 3 : 4)
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

/// Draws the chip from the configuration the `Toggle` hands in, which is the
/// resolved state until the moment of a tap and WidgetKit's optimistic flip
/// for the second or so after it -- the gap between the tap and the reload
/// that confirms it. Both words are given up front so the dot and the label
/// always come from the same side (see `AutoswitchChip`).
struct AutoswitchChipStyle: ToggleStyle {
    /// `at 90%` / `90%`: what the chip says when it is on.
    let onText: String
    /// `Off`.
    let offText: String
    var compact = false
    var symbol = "arrow.triangle.2.circlepath"

    func makeBody(configuration: Configuration) -> some View {
        AutoswitchChip(isOn: configuration.isOn,
                       stateText: configuration.isOn ? onText : offText,
                       compact: compact, symbol: symbol)
    }
}

/// The auto-switch toggle in small's and medium's action spot: the chip on its
/// own, with `85%` or `Off` as its state and the glyph carrying what the wider
/// line says beside itself -- ⏳ while a request is out, ! when the write
/// never landed. Draws nothing when the snapshot carries no auto-switch block:
/// there is then no state to toggle.
struct CompactAutoControl: View {
    let context: PageContext

    var body: some View {
        if let auto = context.snapshot.autoswitch, let toggle = context.toggle {
            let onText = Format.pct(auto.threshold)
            let symbol = symbol(toggle)
            if toggle.isDisabled {
                AutoswitchChip(isOn: toggle.isOn, stateText: toggle.isOn ? onText : "Off",
                               isDisabled: true, compact: true, symbol: symbol)
                    .accessibilityLabel("Auto-switch \(toggle.isOn ? "on" : "off"), backend stopped")
            } else {
                Toggle(isOn: toggle.isOn, intent: SetAutoswitchIntent(enabled: !toggle.isOn)) {
                    EmptyView()
                }
                .toggleStyle(AutoswitchChipStyle(onText: onText, offText: "Off",
                                                 compact: true, symbol: symbol))
                .fixedSize()
                .accessibilityLabel(label(toggle, stateText: onText))
            }
        }
    }

    private func symbol(_ toggle: ToggleResolution) -> String {
        if toggle.isPending { return "clock" }
        if toggle.backendNotRunning { return "exclamationmark.circle" }
        return "arrow.triangle.2.circlepath"
    }

    private func label(_ toggle: ToggleResolution, stateText: String) -> String {
        let state = toggle.isOn ? "on, at \(stateText)" : "off"
        if toggle.isPending { return "Auto-switch \(state), applying" }
        if toggle.backendNotRunning { return "Auto-switch \(state), backend not running" }
        return "Auto-switch \(state)"
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
                let onText = "at \(Format.pct(auto.threshold))"
                if toggle.isDisabled {
                    AutoswitchChip(isOn: toggle.isOn, stateText: toggle.isOn ? onText : "Off",
                                   isDisabled: true)
                        .accessibilityLabel("Auto-switch \(toggle.isOn ? "on" : "off"), backend stopped")
                } else {
                    Toggle(isOn: toggle.isOn, intent: SetAutoswitchIntent(enabled: !toggle.isOn)) {
                        EmptyView()
                    }
                    .toggleStyle(AutoswitchChipStyle(onText: onText, offText: "Off"))
                    .fixedSize()
                    .accessibilityLabel("Auto-switch \(toggle.isOn ? "on, \(onText)" : "off")")
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
