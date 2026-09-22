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

/// `⇄ ClaudeSwap  as of 10:03`, the first line of large and extra-large. When
/// the backend has stopped republishing, the time gives way to saying so.
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
                // The wording shortens before the message is cut short.
                let age = context.now.timeIntervalSince(context.snapshot.takenAt)
                ViewThatFits(in: .horizontal) {
                    backendDown(Format.backendDown(age: age))
                    backendDown("Backend not running · \(Format.age(seconds: age))")
                    backendDown("Backend not running")
                    backendDown("Not running")
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

    private func backendDown(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
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
                }
                .toggleStyle(.switch)
                .controlSize(.regular)
                .fixedSize()
                .contentShape(Rectangle())
                Text(toggle.isOn ? "at \(Format.pct(auto.threshold))" : "Off")
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .fixedSize()
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

struct AccountCard: View {
    let account: Account
    let context: PageContext
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                InitialsBadge(account: account, size: 22)
                AccountTitle(account: account, font: .system(size: 12.5, weight: .semibold))
                    .layoutPriority(1)
                Text(account.subtitle)
                    .font(.system(size: 11))
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
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 11).fill(.primary.opacity(0.06)))
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
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.leading, 42)
    }
}

// MARK: - Extra-large panels

struct TrendPanel: View {
    let context: PageContext
    /// The account drawn heavy; the rest are thin and faded.
    let emphasized: Int?
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
                    Text(span.axisLabels[1])
                    Spacer()
                    Text(span.axisLabels[2])
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                legend
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
