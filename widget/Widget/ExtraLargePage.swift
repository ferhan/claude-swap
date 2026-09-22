import SwiftUI
import WidgetKit

// Extra-large: master-detail. The account list on the left selects in place;
// the right column shows the selected account's pace, details and trend.

struct ExtraLargePage: View {
    let context: PageContext
    /// Already resolved: mode is `.list` and a selection is set when any
    /// account exists.
    let nav: NavState

    var body: some View {
        let chunks = Navigation.listChunks(for: .extraLarge, snapshot: context.snapshot)
        let index = Navigation.chunkIndex(offset: nav.listOffset, chunks: chunks)
        let selected = nav.selectedAccountNumber.flatMap { context.snapshot.account(number: $0) }
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                BrandTitle(context: context)
                AutoStatusLine(context: context)
                ListHeader(family: .extraLarge, chunks: chunks, index: index)
                ForEach(chunks[index], id: \.number) { account in
                    SelectableRow(account: account, context: context,
                                  isSelected: account.number == selected?.number)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 344)
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                if let selected {
                    PacePanel(context: context, account: selected)
                    Divider()
                    SelectedDetail(account: selected, context: context)
                    Divider()
                }
                TrendPanel(context: context, emphasized: selected?.number)
            }
        }
        .background {
            // Taps that miss every control reload instead of opening the host.
            Button(intent: RefreshIntent()) {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
        }
    }
}

/// `ACCOUNTS   ▲ 1–4 of 9 ▼`. The arrows appear only when the list overflows.
struct ListHeader: View {
    let family: LayoutFamily
    let chunks: [[Account]]
    let index: Int

    var body: some View {
        HStack(spacing: 5) {
            Text("ACCOUNTS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if chunks.count > 1 {
                let start = Navigation.chunkStart(index, chunks: chunks)
                let total = chunks.reduce(0) { $0 + $1.count }
                arrow(delta: -1, symbol: "chevron.up", name: "Previous accounts", enabled: index > 0)
                Text("\(start + 1)–\(start + chunks[index].count) of \(total)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize()
                arrow(delta: 1, symbol: "chevron.down", name: "More accounts", enabled: index < chunks.count - 1)
            }
        }
        .frame(height: 22)
    }

    private func arrow(delta: Int, symbol: String, name: String, enabled: Bool) -> some View {
        Button(intent: ScrollListIntent(family: family, delta: delta)) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.primary.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.3)
        .accessibilityLabel(name)
    }
}

/// One account in the list: a button that selects it. The selection is a
/// fill, an outline and a chevron, so it does not rely on color.
///
/// Two lines, ~52pt tall: name, subtitle and tags on the left; each window's
/// percent over its countdown on the right.
struct SelectableRow: View {
    let account: Account
    let context: PageContext
    let isSelected: Bool
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        let accent: Color = mode == .fullColor ? .accentColor : .primary
        Button(intent: SelectAccountIntent(family: context.family, number: account.number)) {
            HStack(spacing: 8) {
                InitialsBadge(account: account, size: 26)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            AccountTitle(account: account, font: .system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.primary)
                            if account.active { ActiveMarker(showsText: false) }
                        }
                        meta
                    }
                    Spacer(minLength: 4)
                    if let fiveHour = account.usage?.fiveHour {
                        column("5h", fiveHour, ticking: true)
                    }
                    if let (title, window) = account.weeklyWindow {
                        column(title == "Weekly" ? "7d" : title, window, ticking: false)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isSelected ? accent : .clear)
                    .widgetAccentable()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? accent.opacity(0.16) : Color.primary.opacity(0.06)))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10).stroke(accent, lineWidth: 1.5).widgetAccentable()
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .opacity(account.isDisabled ? 0.6 : 1)
        .accessibilityLabel("\(account.label)\(isSelected ? ", selected" : "")")
    }

    /// Subtitle (or status, when there is no usage) and the tags. The
    /// subtitle is cut, then dropped, rather than shrunk to a letter.
    private var meta: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) { subtitle.fixedSize(); tags }
            HStack(spacing: 5) { subtitle.frame(minWidth: 48, alignment: .leading); tags }
            HStack(spacing: 5) { tags }
        }
    }

    private var subtitle: some View {
        Text(account.usage == nil ? account.statusText : account.subtitle)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    @ViewBuilder private var tags: some View {
        if account.isStale, let age = account.usageAgeSeconds { AgeLabel(seconds: age) }
        if context.isNext(account) { Tag(text: "Next") }
        if account.isDisabled { Tag(text: "Off") }
    }

    /// `5h 62%` over its timer (ticking for 5h, `3d 11h` for weekly). The
    /// minimum width keeps the columns aligned from row to row; a wide cell
    /// (`Opus ⚠ 100%`) widens its own row rather than being cut.
    private func column(_ title: String, _ window: Window, ticking: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                PctText(pct: window.pct, threshold: context.threshold,
                        font: .system(size: 14, weight: .semibold))
            }
            Countdown(resetsAt: window.resetsAt, now: context.now, ticking: ticking)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
                // A ticking timer otherwise claims all it is offered.
                .frame(width: 66, alignment: .trailing)
        }
        .lineLimit(1)
        .fixedSize()
        .frame(minWidth: 70, alignment: .trailing)
    }
}

/// The selected account's facts and windows, condensed into two columns.
struct SelectedDetail: View {
    let account: Account
    let context: PageContext

    var body: some View {
        let windows = account.windows(maxScoped: Display.maxScopedRows)
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 2) {
                GridRow {
                    key("Email"); value(account.email)
                    key("Org"); value(account.organizationName.isEmpty ? "personal" : account.organizationName)
                }
                GridRow {
                    key("Alias"); value(account.alias ?? "—")
                    key("Kind"); value(account.kind)
                }
                GridRow {
                    key("Status"); value(account.active ? "active · \(account.statusText)" : account.statusText)
                    key("Updated")
                    value(account.usageFetchedAt.map {
                        Format.age(seconds: context.now.timeIntervalSince($0))
                    } ?? "—")
                }
            }
            .font(.system(size: 11.5))
            if windows.isEmpty {
                NoUsage(account: account)
            } else {
                // One column while there is room for real bars; two once
                // per-model windows would push the chart out.
                let columns = windows.count > 2 ? 2 : 1
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(Array(stride(from: 0, to: windows.count, by: columns)), id: \.self) { start in
                        GridRow {
                            ForEach(windows[start..<min(start + columns, windows.count)].indices, id: \.self) { index in
                                row(windows[index])
                            }
                        }
                    }
                }
            }
        }
    }

    private func row(_ pair: (title: String, window: Window)) -> some View {
        WindowRow(title: pair.title, window: pair.window, threshold: context.threshold,
                  now: context.now, ticking: pair.title == "5h", dimmed: account.isStale,
                  titleWidth: 30, compact: true)
    }

    private func key(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).lineLimit(1).fixedSize()
    }

    private func value(_ text: String) -> some View {
        Text(text).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PacePanel: View {
    let context: PageContext
    let account: Account

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Weekly pace").font(.system(size: 12.5, weight: .bold))
                Text("· \(account.label)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if let spend = account.usage?.spend {
                    Text("Spend \(spend.used.formatted(.currency(code: spend.currency))) / "
                         + spend.limit.formatted(.currency(code: spend.currency)))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            if let window = account.usage?.sevenDay {
                // The reset date goes first when the column is narrow; the
                // 7d row below still shows its countdown.
                ViewThatFits(in: .horizontal) {
                    stats(window, showsReset: true)
                    stats(window, showsReset: false)
                }
                UsageBar(pct: window.pct, threshold: context.threshold)
            } else {
                Text("No weekly window for this account.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func stats(_ window: Window, showsReset: Bool) -> some View {
        HStack(alignment: .top, spacing: 16) {
            stat(paceTitle(window), window.expectedPct.map { "\(Format.pct($0)) expected" } ?? "no data yet")
            stat(Format.pct(window.pct), "used")
            if window.willLastToReset == false, let runsOut = window.projectedExhaustionAt {
                stat(runsOut.formatted(.dateTime.weekday(.abbreviated).hour().minute()), "runs out")
            } else if window.willLastToReset == true {
                stat("Lasts", "to reset")
            }
            if showsReset, let resetsAt = window.resetsAt {
                stat(resetsAt.formatted(.dateTime.month(.abbreviated).day()),
                     "resets · \(Format.countdown(to: resetsAt, now: context.now))")
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
            Text(value).font(.system(size: 14, weight: .semibold).monospacedDigit()).lineLimit(1).fixedSize()
            Text(caption).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
    }
}
