import SwiftUI
import WidgetKit

/// A window's pace as a picture: its bar with a tick where usage is expected
/// to be by now, and a verdict.
///
/// Weekly: then when the week runs out and the spend. Time to reset is left
/// out -- the 7d list row already ticks it down -- except once the week is
/// exhausted, when the reset is the only thing left to say.
///
/// Session (extra-large, the 5h window): the verdict and the bar only -- no
/// run-out projection, and no countdown, which the selected card's 5h row
/// already ticks beside it.
struct PaceLine: View {
    enum Kind { case weekly, session }

    let account: Account
    let context: PageContext
    var kind: Kind = .weekly
    @Environment(\.widgetRenderingMode) private var mode
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let window = kind == .weekly ? account.usage?.sevenDay : account.usage?.fiveHour
        let reading = window.map { kind == .weekly ? $0.weeklyReading(now: context.now)
                                                   : $0.sessionReading(now: context.now) }
        let titles = kind == .weekly ? ("Weekly pace", "Weekly") : ("5h session", "5h")
        VStack(alignment: .leading, spacing: 6) {
            if let window, let reading {
                // "Ahead of pace" is long: the title shortens before the
                // expected figure goes (the bar's tick keeps it).
                ViewThatFits(in: .horizontal) {
                    header(window, reading, title: titles.0, showsExpected: true)
                    header(window, reading, title: titles.1, showsExpected: true)
                    header(window, reading, title: titles.1, showsExpected: false)
                }
                UsageBar(pct: window.pct, threshold: context.threshold, height: 8, dimmed: account.isStale)
                    .overlay {
                        if let expected = reading.expectedPct {
                            GeometryReader { geo in
                                // A non-finite position traps in layout.
                                let tickX = geo.size.width * min(max(expected / 100, 0), 1)
                                let tickY = geo.size.height / 2
                                Capsule()
                                    .fill(.primary)
                                    .frame(width: 2, height: 16)
                                    .position(x: tickX.isFinite ? tickX : 0, y: tickY.isFinite ? tickY : 0)
                            }
                            .accessibilityLabel("\(Format.expectedPct(expected)) expected by now")
                        }
                    }
                    .padding(.vertical, 4)
            }
            if kind == .weekly { stats(window) }
        }
    }

    private func stats(_ window: Window?) -> some View {
        HStack(alignment: .top, spacing: 14) {
            if let window {
                switch window.outlook(now: context.now) {
                case .resetsIn(let resetsAt):
                    // The 5h session timer's own form. Not
                    // `Text(timerInterval:)`: WidgetKit's archiving of it
                    // crashed the extension (blank widget) on 2026-09-23.
                    stat("RESETS IN", Text(resetsAt, style: .timer), width: 90)
                case .resetting:
                    stat("RESETS IN", Text("Resetting…"))
                case .runsOut(let runsOut):
                    stat("RUNS OUT", Text(runsOut.formatted(.dateTime.weekday(.abbreviated).hour().minute())),
                         color: mode == .fullColor ? Palette.critical(scheme) : .primary)
                case .lastsToReset:
                    stat("LASTS", Text("to reset"))
                case .unknown:
                    EmptyView()
                }
            }
            if let spend = account.usage?.spend {
                stat("SPEND", Text("\(spend.used.formatted(.currency(code: spend.currency))) / "
                     + spend.limit.formatted(.currency(code: spend.currency))))
            }
            Spacer(minLength: 0)
        }
    }

    private func header(_ window: Window, _ reading: PaceReading, title: String,
                        showsExpected: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).fixedSize()
            verdict(reading.verdict)
            Spacer(minLength: 4)
            // At the limit "expected" has nothing left to compare.
            if showsExpected, let expected = reading.expectedPct {
                Text("\(Format.expectedPct(expected)) expected ·")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Text("used").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
            PctText(pct: window.pct, threshold: context.threshold,
                    font: .system(size: 11, weight: .semibold))
        }
        .lineLimit(1)
    }

    /// `⛔ At limit` / `↗ Ahead of pace` / `On pace` / `Too early` /
    /// `Pace unknown` / `No active session`: a word, with the glyph and the
    /// color only as extra cues. At the limit there is no pace left to judge
    /// -- "On pace" beside 100% read as all clear.
    @ViewBuilder private func verdict(_ verdict: PaceReading.Verdict) -> some View {
        switch verdict {
        case .atLimit:
            Label("At limit", systemImage: "exclamationmark.octagon.fill").labelStyle(.titleAndIcon)
                .foregroundStyle(mode == .fullColor ? Palette.critical(scheme) : .primary)
                .font(.system(size: 11, weight: .semibold)).fixedSize()
        case .ahead:
            Label("Ahead of pace", systemImage: "arrow.up.right").labelStyle(.titleAndIcon)
                .foregroundStyle(mode == .fullColor ? Palette.warning(scheme) : .primary)
                .font(.system(size: 11, weight: .semibold)).fixedSize()
        case .onPace:
            Text("On pace").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(mode == .fullColor ? Palette.good(scheme) : .primary)
                .fixedSize()
        case .tooEarly:
            Text("Too early").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
        case .unknown:
            Text("Pace unknown").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
        case .noSession:
            Text("No active session").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
        }
    }

    /// `width`: a ticking timer gets a fixed frame, as every other timer in
    /// the widget does, rather than `fixedSize()` on text that changes width.
    private func stat(_ caption: String, _ value: Text, color: Color = .primary,
                      width: CGFloat? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(caption).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            if let width {
                value.font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundStyle(color).lineLimit(1).frame(width: width, alignment: .leading)
            } else {
                value.font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundStyle(color).lineLimit(1).fixedSize()
            }
        }
    }
}
