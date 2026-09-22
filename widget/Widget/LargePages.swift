import Charts
import SwiftUI
import WidgetKit

// Large, the detail pages, and the extra-large panels.

// MARK: - Large

/// Large mirrors extra-large in a drill-down: the same account list as the
/// left column there, and the same detail as the right column, stacked -- one
/// at a time, because 344×344 holds one of them.
struct LargePage: View {
    let context: PageContext
    /// Already resolved: a selection is set when any account exists.
    let nav: NavState

    var body: some View {
        let selected = nav.selectedAccountNumber.flatMap { context.snapshot.account(number: $0) }
        if nav.mode == .detail, let selected {
            LargeDetail(account: selected, context: context)
        } else {
            LargeList(context: context, nav: nav, selected: selected)
        }
    }
}

/// The account list: the extra-large left column fitted to 344pt, with
/// "Details ›" on the selected row as the way into the detail.
struct LargeList: View {
    let context: PageContext
    let nav: NavState
    let selected: Account?

    var body: some View {
        let chunks = Navigation.listChunks(for: .large, snapshot: context.snapshot)
        let index = Navigation.chunkIndex(offset: nav.listOffset, chunks: chunks)
        VStack(alignment: .leading, spacing: 6) {
            BrandTitle(context: context)
            AutoStatusLine(context: context)
            ListHeader(family: .large, chunks: chunks, index: index)
            ForEach(chunks[index], id: \.number) { account in
                SelectableRow(account: account, context: context,
                              isSelected: account.number == selected?.number, showsDetails: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// `⇄ ClaudeSwap  as of 10:03`, the first line of large and extra-large. When
/// the backend has stopped republishing, the time gives way to saying so and
/// to a control that starts it.
struct BrandTitle: View {
    let context: PageContext

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tint)
                .widgetAccentable()
            Text("ClaudeSwap").font(.system(size: 14, weight: .bold)).fixedSize()
            if context.isBackendStale {
                // "Backend stopped" and the control to start it. The wording
                // shortens, then goes, before the control is cut.
                let age = context.now.timeIntervalSince(context.snapshot.takenAt)
                ViewThatFits(in: .horizontal) {
                    stopped(Format.backendDown(age: age), short: false)
                    stopped("Backend stopped · \(Format.age(seconds: age))", short: false)
                    stopped("Backend stopped", short: false)
                    stopped("Stopped", short: false)
                    stopped("Stopped", short: true)
                    stopped(nil, short: true)
                }
            } else {
                let time = context.snapshot.takenAt.formatted(date: .omitted, time: .shortened)
                ViewThatFits(in: .horizontal) {
                    asOf("as of \(time)")
                    asOf(time)
                }
            }
        }
    }

    private func asOf(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    /// The words, or with `nil` just the icon, then the Start control.
    private func stopped(_ text: String?, short: Bool) -> some View {
        HStack(spacing: 6) {
            Group {
                if let text {
                    Label(text, systemImage: "exclamationmark.circle").labelStyle(.titleAndIcon)
                } else {
                    Image(systemName: "exclamationmark.circle").accessibilityLabel("Backend stopped")
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            StartBackendControl(context: context, short: short)
        }
    }
}

// MARK: - Trend panel

struct TrendPanel: View {
    let context: PageContext
    /// The account drawn heavy; the rest are thin and faded.
    let emphasized: Int?
    /// Large's detail view: a shorter chart, one axis hint instead of three,
    /// and no legend -- the detail is about one account, which the heavy line
    /// and the rows above already name.
    var compact = false
    @Environment(\.widgetRenderingMode) private var mode

    private static let palette: [Color] = [.blue, .purple, .teal, .pink, .indigo, .brown, .mint]

    var body: some View {
        let span = Trend.span(context.snapshot, now: context.now)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("5h usage · \(span.caption)").font(.system(size: 12.5, weight: .bold)).lineLimit(1)
                Spacer()
                // The words go before the key wraps.
                ViewThatFits(in: .horizontal) {
                    key(threshold: "\(Format.pct(context.threshold)) threshold", switchText: "switch")
                    key(threshold: Format.pct(context.threshold), switchText: nil)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            if Trend.hasData(context.snapshot, now: context.now) {
                chart(span)
                HStack {
                    Text(span.axisLabels[0])
                    Spacer()
                    if !compact {
                        Text(span.axisLabels[1])
                        Spacer()
                    }
                    Text(span.axisLabels[2])
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                if !compact { legend }
            } else {
                Spacer(minLength: 0)
                Label("Trend available when the backend is running", systemImage: "chart.xyaxis.line")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func key(threshold: String, switchText: String?) -> some View {
        HStack(spacing: 8) {
            Label(threshold, systemImage: "line.diagonal")
            if context.snapshot.autoswitch != nil {
                if let switchText {
                    Label(switchText, systemImage: "circle")
                } else {
                    Image(systemName: "circle").accessibilityLabel("switch")
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private struct Line {
        let account: Account
        let points: [HistoryPoint]
        let color: Color
    }

    private var series: [Line] {
        context.snapshot.orderedAccounts.enumerated().compactMap { offset, account in
            let points = Trend.points(account.usage?.fiveHour?.history, now: context.now)
            guard !points.isEmpty else { return nil }
            return Line(account: account, points: points, color: Self.palette[offset % Self.palette.count])
        }
    }

    private func isEmphasized(_ account: Account) -> Bool { account.number == emphasized }

    private func chart(_ span: Trend.Span) -> some View {
        Chart {
            ForEach(series, id: \.account.number) { line in
                ForEach(line.points, id: \.time) { point in
                    LineMark(x: .value("Time", point.time), y: .value("5h %", point.pct),
                             series: .value("Account", line.account.label))
                        .foregroundStyle(mode == .fullColor ? line.color : .primary)
                        .lineStyle(StrokeStyle(lineWidth: isEmphasized(line.account) ? 2.4 : 1.1))
                        .opacity(isEmphasized(line.account) ? 1 : 0.45)
                }
            }
            RuleMark(y: .value("Threshold", context.threshold))
                .foregroundStyle(Color.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            ForEach(Array(Trend.switchMarkers(context.snapshot, now: context.now).enumerated()),
                    id: \.offset) { _, marker in
                PointMark(x: .value("Time", marker.date), y: .value("5h %", marker.pct))
                    .symbol(Circle().strokeBorder(lineWidth: 1.5))
                    .symbolSize(36)
                    .foregroundStyle(Color.primary)
            }
        }
        .chartXScale(domain: span.start...span.end)
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .widgetAccentable()
        // Compact: the one thing that gives way when the detail runs long, so
        // the fact rows above it never have to be cut.
        .frame(minHeight: compact ? 30 : nil, maxHeight: compact ? 46 : .infinity)
    }

    /// The emphasized account first, then as many as fit whole in one line;
    /// the rest are counted rather than truncated to a stub.
    private var legend: some View {
        let ordered = series.filter { isEmphasized($0.account) } + series.filter { !isEmphasized($0.account) }
        return ViewThatFits(in: .horizontal) {
            ForEach((1...max(ordered.count, 1)).reversed(), id: \.self) { count in
                legendRow(Array(ordered.prefix(count)), hidden: ordered.count - count)
            }
        }
    }

    private func legendRow(_ shown: [Line], hidden: Int) -> some View {
        HStack(spacing: 10) {
            ForEach(shown, id: \.account.number) { line in
                HStack(spacing: 3) {
                    Capsule()
                        .fill(mode == .fullColor ? line.color : .primary)
                        .frame(width: 10, height: isEmphasized(line.account) ? 3 : 1.5)
                    Text(line.account.label)
                        .fontWeight(isEmphasized(line.account) ? .semibold : .regular)
                        .lineLimit(1)
                    if let pct = line.account.usage?.fiveHour?.pct {
                        Text(Format.pct(pct)).fontWeight(.semibold).monospacedDigit()
                    }
                }
                .fixedSize()
            }
            if hidden > 0 {
                Text("+\(hidden)").foregroundStyle(.secondary).fixedSize()
            }
        }
        .font(.system(size: 11))
    }
}
