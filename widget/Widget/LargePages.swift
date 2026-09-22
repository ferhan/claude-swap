import Charts
import SwiftUI
import WidgetKit

// Large, the detail pages, and the extra-large panels.

// MARK: - Large (and the left column of extra-large)

struct LargePage: View {
    let context: PageContext
    let page: Page

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                BrandTitle(context: context)
                Spacer(minLength: 4)
                context.pager
            }
            AutoStatusLine(context: context)
            switch page {
            case .overview(let index, _):
                let chunks = Paging.overviewChunks(for: .large, snapshot: context.snapshot)
                ForEach(chunks.indices.contains(index) ? chunks[index] : [], id: \.number) { account in
                    AccountCard(account: account, context: context)
                }
            case .detail(let number):
                if let account = context.snapshot.account(number: number) {
                    LargeDetail(account: account, context: context)
                }
            case .hero:
                EmptyView()
            }
            Spacer(minLength: 0)
        }
    }
}

/// `⇄ cswap  as of 10:03`, the first line of large and extra-large.
struct BrandTitle: View {
    let context: PageContext

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tint)
                .widgetAccentable()
            Text("cswap").font(.system(size: 13, weight: .bold))
            Text("as of \(context.snapshot.takenAt.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// Read-only: the toggle is a later task, so this renders state, not a Toggle.
struct AutoStatusLine: View {
    let context: PageContext

    var body: some View {
        HStack(spacing: 5) {
            if let auto = context.snapshot.autoswitch {
                Image(systemName: auto.enabled ? "checkmark.circle.fill" : "pause.circle")
                    .widgetAccentable(auto.enabled)
                Text(auto.enabled ? "Auto-switch at \(Format.pct(auto.threshold))"
                                  : "Auto-switch off")
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .fixedSize()
                if auto.enabled, let next = context.snapshot.nextCandidate {
                    Text("· next up").fixedSize()
                    InitialsBadge(account: next, size: 14)
                    // The "(12% used)" goes before the name is cut short.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 5) {
                            nextTitle(next).fixedSize()
                            if let peak = next.peakPct { Text("(\(Format.pct(peak)) used)").fixedSize() }
                        }
                        nextTitle(next)
                    }
                }
            } else {
                Image(systemName: "questionmark.circle")
                Text("Auto-switch status unavailable · threshold \(Format.pct(Display.defaultThreshold))")
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func nextTitle(_ account: Account) -> some View {
        AccountTitle(account: account, font: .system(size: 10.5, weight: .semibold))
            .foregroundStyle(.primary)
    }
}

struct AccountCard: View {
    let account: Account
    let context: PageContext
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                InitialsBadge(account: account, size: 18)
                AccountTitle(account: account, font: .system(size: 12, weight: .semibold))
                    .layoutPriority(1)
                Text(account.subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                if account.isStale, let age = account.usageAgeSeconds { AgeLabel(seconds: age) }
                if context.isNext(account) { Tag(text: "Next") }
                if account.active { ActiveMarker() }
                if account.isDisabled { Tag(text: "Disabled") }
            }
            if account.usage != nil {
                ForEach(Array(account.windows(maxScoped: Display.maxScopedRows).enumerated()),
                        id: \.offset) { _, pair in
                    WindowRow(title: pair.title, window: pair.window, threshold: context.threshold,
                              now: context.now, ticking: pair.title == "5h", dimmed: account.isStale)
                    if pair.title == "7d", pair.window.aheadOfPace == true {
                        PaceNote(window: pair.window)
                    }
                }
            } else {
                Text(account.statusText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 11).fill(.primary.opacity(0.05)))
        .overlay {
            if account.active {
                RoundedRectangle(cornerRadius: 11)
                    .stroke(mode == .fullColor ? Color.accentColor : .primary, lineWidth: 1)
                    .widgetAccentable()
            }
        }
        .opacity(account.isDisabled ? 0.6 : 1)
    }
}

struct PaceNote: View {
    let window: Window

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.up.right")
            if let expected = window.expectedPct {
                Text("Ahead of pace · \(Format.pct(expected)) expected by now")
            } else {
                Text("Ahead of pace")
            }
        }
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.leading, 42)
    }
}

// MARK: - Extra-large panels

struct PacePanel: View {
    let context: PageContext
    let account: Account

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Weekly pace").font(.system(size: 11, weight: .bold))
                Text("· \(account.label)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let window = account.usage?.sevenDay {
                HStack(alignment: .top, spacing: 16) {
                    stat(paceTitle(window), window.expectedPct.map { "\(Format.pct($0)) expected by now" }
                            ?? "not enough data yet")
                    stat(Format.pct(window.pct), "used")
                    if window.willLastToReset == false, let runsOut = window.projectedExhaustionAt {
                        stat(runsOut.formatted(date: .abbreviated, time: .shortened), "runs out")
                    } else if window.willLastToReset == true {
                        stat("Lasts", "to reset")
                    }
                    if let resetsAt = window.resetsAt {
                        stat(resetsAt.formatted(.dateTime.month(.abbreviated).day()),
                             "resets · \(Format.countdown(to: resetsAt, now: context.now))")
                    }
                }
                UsageBar(pct: window.pct, threshold: context.threshold)
            } else {
                Text("No weekly window for this account.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            if let spend = account.usage?.spend {
                Text("Spend \(spend.used.formatted(.currency(code: spend.currency))) / "
                     + spend.limit.formatted(.currency(code: spend.currency)))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func paceTitle(_ window: Window) -> String {
        switch window.aheadOfPace {
        case true?: "Ahead"
        case false?: "On pace"
        case nil: "Pace unknown"
        }
    }

    private func stat(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text(caption).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct TrendPanel: View {
    let context: PageContext
    /// The account drawn heavy; the rest are thin and faded.
    let emphasized: Int?
    @Environment(\.widgetRenderingMode) private var mode

    private static let palette: [Color] = [.blue, .purple, .teal, .pink, .indigo, .brown, .mint]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("5h usage · last 24h").font(.system(size: 11, weight: .bold))
                Spacer()
                HStack(spacing: 8) {
                    Label("\(Format.pct(context.threshold)) threshold", systemImage: "line.diagonal")
                    if context.snapshot.autoswitch != nil { Label("switch", systemImage: "circle") }
                }
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            }
            if Trend.hasData(context.snapshot, now: context.now) {
                chart
                HStack {
                    Text("-24h")
                    Spacer()
                    Text("-12h")
                    Spacer()
                    Text("now")
                }
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)
                legend
            } else {
                Spacer(minLength: 0)
                Label("Trend available when the backend is running", systemImage: "chart.xyaxis.line")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
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

    private var chart: some View {
        let start = context.now.addingTimeInterval(-Trend.span)
        return Chart {
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
        .chartXScale(domain: start...context.now)
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .widgetAccentable()
        .frame(maxHeight: .infinity)
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
                        Text(Format.pct(pct)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .fixedSize()
            }
            if hidden > 0 {
                Text("+\(hidden)").foregroundStyle(.secondary).fixedSize()
            }
        }
        .font(.system(size: 9.5))
    }
}
