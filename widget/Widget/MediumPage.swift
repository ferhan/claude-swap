import Charts
import SwiftUI
import WidgetKit

// Medium, 344x164: the picture on the left, the account on the right.

/// Medium is master-detail for one account at a time: that account's usage as
/// a picture on the left and its identity and facts on the right. Nothing is
/// drawn in both columns -- the name and email belong to the right one -- and
/// the ‹ › in the bottom-right move the selection, not a page; there is no
/// detail page to drill into.
struct MediumPage: View {
    let context: PageContext
    /// Already resolved: mode is `.list` and a selection is set.
    let nav: NavState

    var body: some View {
        let accounts = context.snapshot.orderedAccounts
        let selected = nav.selectedAccountNumber.flatMap { context.snapshot.account(number: $0) }
            ?? accounts[0]
        HStack(spacing: 10) {
            MediumVisual(account: selected, context: context)
                .frame(width: 150)
            Divider()
            MediumDetail(account: selected, accounts: accounts, context: context)
        }
    }
}

/// The left column, 150pt: the selected account's state as a picture -- the 5h
/// ring with its ticking countdown, the weekly bar, and the 5h sparkline under
/// them. With the name line moved to the right column the ring takes the
/// freed height, and a stopped backend puts the control that starts it here,
/// where the trend it has no data for would be.
struct MediumVisual: View {
    let account: Account
    let context: PageContext

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if account.usage != nil {
                HeroGauge(account: account, context: context, ringSize: 64)
                Spacer(minLength: 5)
                HeroWeekly(account: account, context: context)
            } else {
                // Nothing to plot: the one line there is sits in the middle of
                // the column rather than at the top of an empty one.
                Spacer(minLength: 5)
                NoUsage(account: account)
            }
            Spacer(minLength: 5)
            if context.isBackendStale {
                StartBackendControl(context: context, compact: true)
            } else {
                MiniTrend(account: account, context: context)
            }
        }
    }
}

/// The selected account's 5h line over the trend's own time axis, with the
/// threshold as a dashed rule: 34pt of chart and a caption, which is what the
/// left column has room for. Nothing when there is no history to draw.
struct MiniTrend: View {
    let account: Account
    let context: PageContext
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        let points = Trend.points(account.usage?.fiveHour?.history, now: context.now)
        if points.count > 1 {
            let span = Trend.span(context.snapshot, now: context.now)
            VStack(alignment: .leading, spacing: 2) {
                Text("5h · \(span.caption)")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Chart {
                    ForEach(points, id: \.time) { point in
                        AreaMark(x: .value("Time", point.time), y: .value("5h %", point.pct))
                            .foregroundStyle((mode == .fullColor ? Color.accentColor : .primary)
                                .opacity(0.18))
                        LineMark(x: .value("Time", point.time), y: .value("5h %", point.pct))
                            .foregroundStyle(mode == .fullColor ? Color.accentColor : .primary)
                            .lineStyle(StrokeStyle(lineWidth: 1.8))
                    }
                    RuleMark(y: .value("Threshold", context.threshold))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                .chartXScale(domain: span.start...span.end)
                .chartYScale(domain: 0...100)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .widgetAccentable()
                .frame(height: 34)
            }
            .accessibilityLabel("5h usage trend, \(span.caption)")
        }
    }
}

/// The right column, 147pt: who the account is -- badge, email and the green
/// dot when it is the one in use -- its facts, and on the bottom line the one
/// action spot beside the ‹ ›, placed as small places them. Everything the
/// left column draws -- ring, bar, percentages, countdowns -- is left out, and
/// so is the email, which is called out here and nowhere else.
///
/// At this width "BY MODEL" is the one thing from the extra-large right column
/// that does not fit.
struct MediumDetail: View {
    let account: Account
    let accounts: [Account]
    let context: PageContext

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // A line of its own: at this width half a grid cell cut every
            // address worth reading.
            HStack(spacing: 5) {
                InitialsBadge(account: account, size: 18)
                Text(account.email)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .truncationMode(.tail)
                if account.active { ActiveMarker(showsText: false) }
                Spacer(minLength: 0)
            }
            AccountFactsGrid(account: account, context: context, compact: true)
            Spacer(minLength: 2)
            HStack(spacing: 4) {
                CompactActionControl(account: account, context: context)
                Spacer(minLength: 2)
                SelectionPager(account: account, accounts: accounts, family: context.family)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// `‹ 2/6 ›`: which account the widget is on, and the arrows that move it.
/// They select rather than page -- the same `SelectAccountIntent` a row tap
/// runs on the larger sizes -- so medium's whole navigation is the selection.
struct SelectionPager: View {
    let account: Account
    let accounts: [Account]
    let family: LayoutFamily

    var body: some View {
        let position = (accounts.firstIndex { $0.number == account.number } ?? 0) + 1
        HStack(spacing: 4) {
            button(delta: -1, symbol: "chevron.left", name: "Previous account")
            Text("\(position)/\(accounts.count)")
                .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            button(delta: 1, symbol: "chevron.right", name: "Next account")
        }
    }

    private func button(delta: Int, symbol: String, name: String) -> some View {
        let target = Navigation.neighbor(of: account.number, in: accounts, by: delta) ?? account.number
        return Button(intent: SelectAccountIntent(family: family, number: target)) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(.primary.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(accounts.count > 1 ? 1 : 0.3)
        .accessibilityLabel(name)
    }
}
