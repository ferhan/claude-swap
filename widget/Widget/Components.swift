import SwiftUI
import WidgetKit

// MARK: - Type scale

extension EnvironmentValues {
    /// Large and extra-large: the legible type scale -- nothing under 11pt,
    /// numbers in the primary color.
    @Entry var largeType = false
}

// MARK: - Colors and glyphs

extension Tone {
    var color: Color {
        switch self {
        case .green: .green
        case .yellow: .yellow
        case .orange: .orange
        case .red: .red
        }
    }
}

extension Severity {
    /// Status is never color-only: warning and critical always carry a glyph.
    var symbol: String? {
        switch self {
        case .normal: nil
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "exclamationmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .normal: .primary
        case .warning: .orange
        case .critical: .red
        }
    }
}

private func rampGradientStops(_ threshold: Double) -> [Gradient.Stop] {
    Ramp.stops(threshold: threshold).map { Gradient.Stop(color: $0.tone.color, location: $0.location) }
}

/// Diagonal bands, cut out of a critical fill so the state reads without color.
struct Stripes: Shape {
    var pitch: CGFloat = 4
    var band: CGFloat = 1.6

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var left = -rect.height
        while left < rect.width + rect.height {
            path.move(to: CGPoint(x: left, y: rect.maxY))
            path.addLine(to: CGPoint(x: left + band, y: rect.maxY))
            path.addLine(to: CGPoint(x: left + band + rect.height, y: rect.minY))
            path.addLine(to: CGPoint(x: left + rect.height, y: rect.minY))
            path.closeSubpath()
            left += pitch
        }
        return path
    }
}

// MARK: - Percent text

struct PctText: View {
    let pct: Double
    let threshold: Double
    var font: Font = .caption.weight(.semibold)
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        let severity = Severity(pct: pct, threshold: threshold)
        HStack(spacing: 2) {
            if let symbol = severity.symbol {
                Image(systemName: symbol).imageScale(.small)
            }
            Text(Format.pct(pct)).monospacedDigit()
        }
        .font(font)
        .foregroundStyle(mode == .fullColor ? severity.color : .primary)
        .lineLimit(1)
        .fixedSize()
    }
}

// MARK: - Bar

/// A usage bar: fixed ramp across the full track, clipped to the fill, with a
/// threshold tick. Critical fills are striped.
struct UsageBar: View {
    let pct: Double
    let threshold: Double
    var height: CGFloat = 6
    var dimmed = false
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        let fraction = min(max(pct / 100, 0), 1)
        let critical = Severity(pct: pct, threshold: threshold) == .critical
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.12))
                fill
                    .frame(width: width)
                    .mask(alignment: .leading) {
                        Capsule()
                            .frame(width: fraction > 0 ? max(width * fraction, height) : 0)
                            .overlay {
                                if critical { Stripes().blendMode(.destinationOut) }
                            }
                            .compositingGroup()
                    }
                    .opacity(dimmed ? 0.5 : 1)
                Capsule()
                    .fill(.primary.opacity(0.45))
                    .frame(width: 2, height: height + 4)
                    .offset(x: width * min(max(threshold / 100, 0), 1) - 1)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }

    @ViewBuilder private var fill: some View {
        if mode == .fullColor {
            LinearGradient(stops: rampGradientStops(threshold), startPoint: .leading, endPoint: .trailing)
        } else {
            Rectangle().fill(.primary).widgetAccentable()
        }
    }
}

// MARK: - Ring

/// The 5h gauge: angular ramp from 12 o'clock, clipped to the fill, with a
/// threshold tick and the percentage in the middle.
struct UsageRing: View {
    let pct: Double?
    let threshold: Double
    var size: CGFloat = 54
    var lineWidth: CGFloat = 6
    var dimmed = false
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        let fraction = min(max((pct ?? 0) / 100, 0), 1)
        let critical = pct.map { Severity(pct: $0, threshold: threshold) == .critical } ?? false
        let diameter = size - lineWidth
        ZStack {
            Circle()
                .stroke(.primary.opacity(0.12), lineWidth: lineWidth)
                .frame(width: diameter, height: diameter)
            fill
                .mask {
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                        .frame(width: diameter, height: diameter)
                        .overlay {
                            if critical { Stripes().blendMode(.destinationOut) }
                        }
                        .compositingGroup()
                }
                .opacity(dimmed ? 0.5 : 1)
            Capsule()
                .fill(.primary.opacity(0.5))
                .frame(width: 2, height: lineWidth + 4)
                .offset(y: -diameter / 2)
                .rotationEffect(.degrees(360 * min(max(threshold / 100, 0), 1)))
            // The glyph sits beside "5h", not the number: the ring's inside
            // is too narrow for both at a readable size.
            let severity = pct.map { Severity(pct: $0, threshold: threshold) } ?? .normal
            VStack(spacing: 0) {
                Text(pct.map(Format.pct) ?? "—")
                    .font(.system(size: 14, weight: .bold).monospacedDigit())
                    .foregroundStyle(mode == .fullColor ? severity.color : .primary)
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
                HStack(spacing: 2) {
                    if let symbol = severity.symbol {
                        Image(systemName: symbol)
                            .foregroundStyle(mode == .fullColor ? severity.color : .primary)
                    }
                    Text("5h").foregroundStyle(.secondary)
                }
                .font(.system(size: 9, weight: .semibold))
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private var fill: some View {
        if mode == .fullColor {
            AngularGradient(stops: rampGradientStops(threshold), center: .center,
                            startAngle: .degrees(-90), endAngle: .degrees(270))
        } else {
            Rectangle().fill(.primary).widgetAccentable()
        }
    }
}

// MARK: - Account chrome

struct InitialsBadge: View {
    let account: Account
    var size: CGFloat = 20
    @Environment(\.widgetRenderingMode) private var mode
    @Environment(\.largeType) private var largeType

    var body: some View {
        let accent = account.active && mode == .fullColor
        let scaled = size * (account.initials.count > 1 ? 0.42 : 0.5)
        Text(account.initials)
            .font(.system(size: largeType ? max(scaled, 11) : scaled, weight: .bold))
            .foregroundStyle(accent ? Color.accentColor : .secondary)
            .frame(width: size, height: size)
            .background(Circle().fill(accent ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.1)))
            .widgetAccentable(account.active)
    }
}

struct AccountTitle: View {
    let account: Account
    var font: Font = .system(size: 12.5, weight: .semibold)

    var body: some View {
        Text(account.label)
            .font(font)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

struct ActiveMarker: View {
    var showsText = true
    @Environment(\.widgetRenderingMode) private var mode
    @Environment(\.largeType) private var largeType

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(mode == .fullColor ? Color.green : .primary).frame(width: 6, height: 6)
            if showsText { Text("Active") }
        }
        .font(.system(size: largeType ? 11 : 10, weight: .semibold))
        .widgetAccentable()
        .accessibilityLabel("Active account")
    }
}

struct Tag: View {
    let text: String
    @Environment(\.largeType) private var largeType

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: largeType ? 11 : 8.5, weight: .bold))
            .padding(.horizontal, largeType ? 5 : 4)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary, lineWidth: 1))
            .foregroundStyle(.secondary)
            .fixedSize()
    }
}

struct AgeLabel: View {
    let seconds: Double
    @Environment(\.largeType) private var largeType

    var body: some View {
        Label(Format.age(seconds: seconds), systemImage: "clock")
            .labelStyle(.titleAndIcon)
            .font(.system(size: largeType ? 11 : 9.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }
}

// MARK: - Window row

/// `5h ▰▰▰▱ 62% 3:29:12`. The 5h countdown ticks; weekly ones are human.
struct WindowRow: View {
    let title: String
    let window: Window
    let threshold: Double
    let now: Date
    var ticking = false
    var dimmed = false
    var titleWidth: CGFloat = 36
    /// Small widget: tighter columns so the bar keeps some length.
    var compact = false
    @Environment(\.largeType) private var largeType

    var body: some View {
        if largeType {
            // Numbers 13pt, in the primary color; the title is the only label.
            HStack(spacing: compact ? 5 : 6) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: titleWidth, alignment: .leading)
                UsageBar(pct: window.pct, threshold: threshold, dimmed: dimmed)
                PctText(pct: window.pct, threshold: threshold, font: .system(size: 13, weight: .semibold))
                    .frame(width: 50, alignment: .trailing)
                Countdown(resetsAt: window.resetsAt, now: now, ticking: ticking)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.primary)
                    .frame(width: compact ? 62 : 66, alignment: .trailing)
            }
        } else {
            HStack(spacing: compact ? 4 : 6) {
                Text(title)
                    .font(.system(size: compact ? 9.5 : 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: titleWidth, alignment: .leading)
                UsageBar(pct: window.pct, threshold: threshold, dimmed: dimmed)
                PctText(pct: window.pct, threshold: threshold,
                        font: .system(size: compact ? 9.5 : 10.5, weight: .semibold))
                    .frame(width: compact ? 38 : 44, alignment: .trailing)
                Countdown(resetsAt: window.resetsAt, now: now, ticking: ticking)
                    .font(.system(size: compact ? 9 : 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: compact ? 42 : 50, alignment: .trailing)
            }
        }
    }
}

struct Countdown: View {
    let resetsAt: Date?
    let now: Date
    var ticking = false

    var body: some View {
        if let resetsAt, resetsAt > now {
            if ticking {
                Text(resetsAt, style: .timer).multilineTextAlignment(.trailing).lineLimit(1)
            } else {
                Text(Format.countdown(to: resetsAt, now: now)).lineLimit(1)
            }
        } else if resetsAt != nil {
            Text("now")
        } else {
            Text("")
        }
    }
}

// MARK: - Pager

struct Pager: View {
    let family: LayoutFamily
    let label: String
    @Environment(\.largeType) private var largeType

    var body: some View {
        HStack(spacing: 5) {
            button(step: -1, symbol: "chevron.left", name: "Previous page")
            Text(label)
                .font(.system(size: largeType ? 11 : 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 22)
            button(step: 1, symbol: "chevron.right", name: "Next page")
        }
    }

    private func button(step: Int, symbol: String, name: String) -> some View {
        Button(intent: PageIntent(family: family, step: step)) {
            Image(systemName: symbol)
                .font(.system(size: largeType ? 11 : 9, weight: .bold))
                .frame(width: largeType ? 24 : 20, height: largeType ? 24 : 20)
                .background(Circle().fill(.primary.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }
}
