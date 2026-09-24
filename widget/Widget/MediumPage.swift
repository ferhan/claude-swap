import Charts
import SwiftUI
import WidgetKit

// Medium, 344x164: the account and its usage on the left, the trend and the
// controls on the right.

/// Medium is master-detail for one account at a time: who it is and its usage
/// on the left, its 5h trend and what can be done about it on the right. The
/// ‹ › move the selection, not a page; there is no detail page to drill into.
struct MediumPage: View {
    let context: PageContext
    /// Already resolved: mode is `.list` and a selection is set.
    let nav: NavState

    var body: some View {
        let accounts = context.snapshot.orderedAccounts
        let selected = nav.selectedAccountNumber.flatMap { context.snapshot.account(number: $0) }
            ?? accounts[0]
        HStack(spacing: 10) {
            MediumVisual(account: selected, accounts: accounts, context: context)
                .frame(width: 150)
            Divider()
            MediumDetail(account: selected, context: context)
        }
    }
}

/// The left column, 150pt: the account -- badge, email, the green dot when it
/// is the one in use -- then the 5h ring with its ticking countdown and the
/// weekly bar, and on the bottom line its auth type beside the ‹ ›.
struct MediumVisual: View {
    let account: Account
    let accounts: [Account]
    let context: PageContext

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A line of its own: at this width half a line cut every address
            // worth reading.
            HStack(spacing: 5) {
                InitialsBadge(account: account, size: 18)
                Text(account.email)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(minScale(10.5))
                    .truncationMode(.tail)
                if account.active { ActiveMarker(showsText: false) }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 3)
            if account.usage != nil {
                HeroGauge(account: account, context: context, ringSize: 58)
                Spacer(minLength: 3)
                HeroWeekly(account: account, context: context)
            } else {
                NoUsage(account: account)
            }
            Spacer(minLength: 3)
            HStack(spacing: 4) {
                if let auth = account.authLabel { Tag(text: auth, uppercased: false) }
                Spacer(minLength: 2)
                SelectionPager(account: account, accounts: accounts, family: context.family)
            }
        }
    }
}

/// The selected account's 5h line over the trend's own time axis, with the
/// threshold as a dashed rule; the chart takes the height the column leaves
/// it. Nothing when there is no history to draw.
struct MiniTrend: View {
    let account: Account
    let context: PageContext
    @Environment(\.widgetRenderingMode) private var mode
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let points = Trend.points(account.usage?.fiveHour?.history, now: context.now)
        if points.count > 1 {
            let span = Trend.span(context.snapshot, now: context.now)
            VStack(alignment: .leading, spacing: 2) {
                Text("5h · \(span.caption)")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(minScale(8.5))
                Chart {
                    ForEach(points, id: \.time) { point in
                        AreaMark(x: .value("Time", point.time), y: .value("5h %", point.pct))
                            .foregroundStyle((mode == .fullColor ? Palette.accent(scheme) : .primary)
                                .opacity(0.18))
                        LineMark(x: .value("Time", point.time), y: .value("5h %", point.pct))
                            .foregroundStyle(mode == .fullColor ? Palette.accent(scheme) : .primary)
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
                .frame(minHeight: 34, maxHeight: .infinity)
            }
            .accessibilityLabel("5h usage trend, \(span.caption)")
        }
    }
}

/// The right column: the 5h trend, how old the numbers are, and the two
/// controls -- the auto-switch chip and the switch control, which reads
/// "Active" on the account in use. A stopped backend puts the control that
/// starts it where the trend it has no data for would be.
struct MediumDetail: View {
    let account: Account
    let context: PageContext

    var body: some View {
        let eligibility = account.switchEligibility(activeNumber: context.snapshot.activeAccountNumber)
        VStack(alignment: .leading, spacing: 4) {
            if context.isBackendStale {
                Spacer(minLength: 0)
                StartBackendControl(context: context, compact: true)
            } else {
                MiniTrend(account: account, context: context)
            }
            Spacer(minLength: 0)
            if let age = account.usageAgeSeconds {
                AgeLabel(seconds: age).accessibilityLabel("Updated \(Format.age(seconds: age))")
            }
            HStack(spacing: 4) {
                CompactAutoControl(context: context)
                Spacer(minLength: 2)
                // The start control above already offers the only thing a
                // switch would need.
                if !(context.isBackendStale && eligibility == .eligible) {
                    SwitchControl(account: account, context: context, compact: true)
                }
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
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
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
