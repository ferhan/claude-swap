import SwiftUI
import WidgetKit

// The auto-switch controls: the full switch on large and extra-large, the
// small one on small and medium, and the status line under the large title.

/// The drawn switch: a track that fills green and a knob that sits right when
/// on. SwiftUI shapes rather than `.toggleStyle(.switch)`: AppKit's switch is
/// not one of the controls a widget's out-of-process renderer can draw, so it
/// came out as the yellow "unsupported view" placeholder.
struct SwitchTrack: View {
    let isOn: Bool
    var width: CGFloat = 32
    var height: CGFloat = 19
    @Environment(\.widgetRenderingMode) private var mode
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let knob = height - 4
        Capsule()
            .fill(track)
            .frame(width: width, height: height)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(.white).frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                    .padding(2)
            }
            .widgetAccentable(isOn)
    }

    private var track: Color {
        guard isOn else { return .primary.opacity(0.2) }
        return mode == .fullColor ? Palette.switchOn(scheme) : .primary
    }
}

/// Small's and medium's auto-switch toggle: the small switch, then the
/// threshold as plain text. A glyph in front carries what there is no room to
/// say -- a clock while a request is out, ! when the write never landed.
///
/// Knob and track come from `isOn` alone -- one value, so they cannot
/// disagree. An earlier chip bound only its dot to the `Toggle`'s own binding,
/// which WidgetKit flips optimistically the moment it is tapped, and left its
/// words on the resolved state: the dot went green beside a label still
/// reading "Off". The optimistic flip is kept -- it is the only feedback in
/// the second or so before a reload can land.
struct AutoswitchChip: View {
    let isOn: Bool
    /// `90%`: information, not state -- the knob's position carries that.
    let threshold: String
    var isDisabled = false
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            }
            SwitchTrack(isOn: isOn, width: 24, height: 14)
            Text(threshold)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .minimumScaleFactor(minScale(10))
        }
        .lineLimit(1)
        .contentShape(Rectangle())
        .opacity(isDisabled ? 0.5 : 1)
    }
}

/// Draws the chip from the configuration the `Toggle` hands in: the resolved
/// state until a tap, and WidgetKit's optimistic flip for the moment after.
struct AutoswitchChipStyle: ToggleStyle {
    let threshold: String
    var symbol: String?

    func makeBody(configuration: Configuration) -> some View {
        AutoswitchChip(isOn: configuration.isOn, threshold: threshold, symbol: symbol)
    }
}

/// The auto-switch toggle in small's and medium's action spot. Draws nothing
/// when the snapshot carries no auto-switch block: there is then no state to
/// toggle. With the backend stopped it is inert, drawn dimmed.
struct CompactAutoControl: View {
    let context: PageContext

    var body: some View {
        if let auto = context.snapshot.autoswitch, let toggle = context.toggle {
            let threshold = Format.pct(auto.threshold)
            let symbol = symbol(toggle)
            if toggle.isDisabled {
                AutoswitchChip(isOn: toggle.isOn, threshold: threshold, isDisabled: true, symbol: symbol)
                    .accessibilityLabel("Auto-switch \(toggle.isOn ? "on" : "off"), backend stopped")
            } else {
                Toggle(isOn: toggle.isOn, intent: SetAutoswitchIntent(enabled: !toggle.isOn)) {
                    EmptyView()
                }
                .toggleStyle(AutoswitchChipStyle(threshold: threshold, symbol: symbol))
                .accessibilityLabel(label(toggle, threshold: threshold))
            }
        }
    }

    private func symbol(_ toggle: ToggleResolution) -> String? {
        if toggle.isPending { return "clock" }
        if toggle.backendNotRunning { return "exclamationmark.circle" }
        return nil
    }

    private func label(_ toggle: ToggleResolution, threshold: String) -> String {
        let state = toggle.isOn ? "on, at \(threshold)" : "off"
        if toggle.isPending { return "Auto-switch \(state), applying" }
        if toggle.backendNotRunning { return "Auto-switch \(state), backend not running" }
        return "Auto-switch \(state)"
    }
}

/// Large and extra-large: "Auto-switch On" and the full-size switch. The word
/// and the knob both come from `isOn` (see `AutoswitchChip`).
struct AutoswitchSwitch: View {
    let isOn: Bool
    var isDisabled = false

    var body: some View {
        HStack(spacing: 6) {
            Text("Auto-switch").font(.system(size: 11, weight: .semibold))
            Text(isOn ? "On" : "Off").font(.system(size: 11)).foregroundStyle(.secondary)
            SwitchTrack(isOn: isOn)
        }
        .lineLimit(1)
        .fixedSize()
        .contentShape(Rectangle())
        .opacity(isDisabled ? 0.5 : 1)
    }
}

/// Feeds `AutoswitchSwitch` from the `Toggle`'s configuration, optimistic
/// flip included (see `AutoswitchChipStyle`).
struct AutoswitchSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        AutoswitchSwitch(isOn: configuration.isOn)
    }
}

/// Large and extra-large: the auto-switch toggle at the end of the title line.
/// With the backend stopped it is inert -- nothing would apply a request, and
/// the title line offers "Start backend" instead. Nothing when the snapshot
/// carries no auto-switch block.
struct AutoswitchHeaderToggle: View {
    let context: PageContext

    var body: some View {
        if let auto = context.snapshot.autoswitch, let toggle = context.toggle {
            let onText = "at \(Format.pct(auto.threshold))"
            if toggle.isDisabled {
                AutoswitchSwitch(isOn: toggle.isOn, isDisabled: true)
                    .accessibilityLabel("Auto-switch \(toggle.isOn ? "on" : "off"), backend stopped")
            } else {
                Toggle(isOn: toggle.isOn, intent: SetAutoswitchIntent(enabled: !toggle.isOn)) {
                    EmptyView()
                }
                .toggleStyle(AutoswitchSwitchStyle())
                .fixedSize()
                .accessibilityLabel("Auto-switch \(toggle.isOn ? "on, \(onText)" : "off")")
            }
        }
    }
}

/// The line under the title: what auto-switch will do -- its threshold and
/// who is next up -- or why it is not doing it yet. The toggle itself sits on
/// the title line (`AutoswitchHeaderToggle`); this line never repeats on/off
/// in words, so the toggle's optimistic flip cannot contradict it.
struct AutoStatusLine: View {
    let context: PageContext

    var body: some View {
        HStack(spacing: 5) {
            if let auto = context.snapshot.autoswitch, let toggle = context.toggle {
                let threshold = Format.pct(auto.threshold)
                if toggle.isPending {
                    Label("Applying…", systemImage: "clock").labelStyle(.titleAndIcon).fixedSize()
                } else if toggle.backendNotRunning {
                    ViewThatFits(in: .horizontal) {
                        notRunning("backend not running")
                        notRunning("not running")
                    }
                } else if toggle.isOn, !toggle.isDisabled, let next = context.snapshot.nextCandidate {
                    // The "(12% used)" goes first, then the name; the badge
                    // stays rather than showing a stub of the name.
                    Text("Switches at \(threshold) · next up").fixedSize()
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 5) {
                            InitialsBadge(account: next, size: 16)
                            nextTitle(next).fixedSize()
                            if let peak = next.peakPct { Text("(\(Format.pct(peak)) used)").fixedSize() }
                        }
                        HStack(spacing: 5) {
                            InitialsBadge(account: next, size: 16)
                            nextTitle(next).fixedSize()
                        }
                        InitialsBadge(account: next, size: 16)
                    }
                } else {
                    Text(toggle.isOn ? "Switches at \(threshold)" : "Would switch at \(threshold) when on")
                        .fixedSize()
                }
            } else {
                Image(systemName: "questionmark.circle")
                Text("Auto-switch status unavailable · threshold \(Format.pct(Display.defaultThreshold))")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        // Right-aligned, under the toggle it describes.
        .frame(maxWidth: .infinity, minHeight: 18, alignment: .trailing)
    }

    private func notRunning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle")
            .labelStyle(.titleAndIcon)
            .fixedSize()
    }

    private func nextTitle(_ account: Account) -> some View {
        AccountTitle(account: account, font: .system(size: 11, weight: .semibold))
            .foregroundStyle(.primary)
    }
}
