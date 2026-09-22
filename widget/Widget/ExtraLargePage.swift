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
            VStack(alignment: .leading, spacing: 6) {
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
            VStack(alignment: .leading, spacing: 8) {
                if let selected {
                    SelectedDetail(account: selected, context: context)
                    Divider()
                    ModelUsagePanel(account: selected, context: context)
                    Divider()
                }
                TrendPanel(context: context, emphasized: selected?.number)
            }
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
/// Three lines, ~68pt tall. The name -- alias and email both -- gets a line of
/// its own so neither half is cut; under it one line per window, each with its
/// bar, percent and countdown.
struct SelectableRow: View {
    let account: Account
    let context: PageContext
    let isSelected: Bool
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        let accent: Color = mode == .fullColor ? .accentColor : .primary
        Button(intent: SelectAccountIntent(family: context.family, number: account.number)) {
            HStack(alignment: .top, spacing: 8) {
                InitialsBadge(account: account, size: 26)
                VStack(alignment: .leading, spacing: 4) {
                    nameLine(accent: accent)
                    if account.usage == nil {
                        Text(account.statusText)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        if let fiveHour = account.usage?.fiveHour {
                            window("5H", fiveHour, ticking: true)
                        }
                        // Always "7D", even when the plan's only weekly limits
                        // are per-model: which model it is belongs to the
                        // detail column, and a name here would cut the bar.
                        if let weekly = account.weeklyWindow?.window {
                            window("7D", weekly, ticking: false)
                        }
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
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
        .accessibilityLabel("\(account.fullName)\(isSelected ? ", selected" : "")")
    }

    /// `work — dev@example.com`, then the markers and the selection chevron.
    /// The age label goes before the name is cut, and the name is cut from
    /// the tail -- never through the middle, which hid which account it was.
    private func nameLine(accent: Color) -> some View {
        ViewThatFits(in: .horizontal) {
            line(accent: accent, showsAge: true, fixedName: true)
            line(accent: accent, showsAge: false, fixedName: true)
            line(accent: accent, showsAge: false, fixedName: false)
        }
    }

    private func line(accent: Color, showsAge: Bool, fixedName: Bool) -> some View {
        HStack(spacing: 6) {
            Text(account.fullName)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .fixedSize(horizontal: fixedName, vertical: false)
            if account.active { ActiveMarker(showsText: false) }
            Spacer(minLength: 4)
            tags(showsAge: showsAge)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isSelected ? accent : .clear)
                .widgetAccentable()
        }
    }

    @ViewBuilder private func tags(showsAge: Bool) -> some View {
        if showsAge, account.isStale, let age = account.usageAgeSeconds { AgeLabel(seconds: age) }
        if context.isNext(account) { Tag(text: "Next") }
        if account.isDisabled { Tag(text: "Off") }
    }

    /// `5H ▰▰▰▱ 62% 40:28:47`: the ramp bar with its threshold tick, the
    /// percent with its severity glyph, and the countdown (ticking for 5h).
    private func window(_ title: String, _ window: Window, ticking: Bool) -> some View {
        WindowRow(title: title, window: window, threshold: context.threshold,
                  now: context.now, ticking: ticking, dimmed: account.isStale,
                  titleWidth: 26, compact: true)
    }
}

/// The selected account's facts, and what the list rows do not already say:
/// how the week is pacing, and the spend. The 5h/7d bars, percentages and
/// countdowns live in the list rows now and are deliberately not repeated.
struct SelectedDetail: View {
    let account: Account
    let context: PageContext

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SELECTED ACCOUNT")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 2) {
                // Email, org and status get the full width and wrap: all
                // three run long, and half a column cut them mid-word.
                GridRow {
                    key("Email"); value(account.email).gridCellColumns(3)
                }
                GridRow {
                    key("Org")
                    value(account.organizationName.isEmpty ? "personal" : account.organizationName)
                        .gridCellColumns(3)
                }
                GridRow {
                    key("Alias"); value(account.alias ?? "—")
                    key("Kind"); value(account.kind)
                }
                GridRow {
                    key("Status")
                    value(account.active ? "active · \(account.statusText)" : account.statusText)
                    key("Updated")
                    value(account.usageFetchedAt.map {
                        Format.age(seconds: context.now.timeIntervalSince($0))
                    } ?? "—")
                }
            }
            .font(.system(size: 11.5))
            if account.usage == nil {
                NoUsage(account: account)
            } else {
                PaceLine(account: account)
            }
        }
    }

    private func key(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).lineLimit(1).fixedSize()
    }

    /// Wraps to a second line rather than cutting: at this width a middle
    /// truncation turned a long org name into `ferhane...ganization`.
    private func value(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.primary)
            .lineLimit(2)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The weekly figures the list rows do not carry: pace against expectation,
/// when the week runs out, and the spend. Everything time-to-reset was
/// dropped -- the 7D row already ticks it down.
struct PaceLine: View {
    let account: Account

    var body: some View {
        let window = account.usage?.sevenDay
        HStack(alignment: .top, spacing: 14) {
            if let window {
                stat(paceTitle(window), window.expectedPct.map { "\(Format.pct($0)) expected" } ?? "no pace data")
                if window.willLastToReset == false, let runsOut = window.projectedExhaustionAt {
                    stat(runsOut.formatted(.dateTime.weekday(.abbreviated).hour().minute()), "runs out")
                } else if window.willLastToReset == true {
                    stat("Lasts", "to reset")
                }
            }
            if let spend = account.usage?.spend {
                stat(spend.used.formatted(.currency(code: spend.currency)),
                     "of \(spend.limit.formatted(.currency(code: spend.currency))) spent")
            }
            Spacer(minLength: 0)
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
            Text(value).font(.system(size: 13, weight: .semibold).monospacedDigit()).lineLimit(1).fixedSize()
            Text(caption).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
    }
}

/// The per-model weekly limits -- Opus, Sonnet, Haiku, Fable. The only place
/// in the widget these appear, so the list rows stay to 5h and 7d.
struct ModelUsagePanel: View {
    let account: Account
    let context: PageContext

    var body: some View {
        let rows = account.scopedWindows
        VStack(alignment: .leading, spacing: 5) {
            Text("BY MODEL · WEEKLY")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if rows.isEmpty {
                Text(account.usage == nil ? "No usage to break down."
                                          : "This plan has no per-model limits.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, pair in
                    row(pair)
                }
            }
        }
    }

    private func row(_ pair: (title: String, window: Window)) -> some View {
        HStack(spacing: 8) {
            Text(pair.title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 52, alignment: .leading)
            UsageBar(pct: pair.window.pct, threshold: context.threshold, dimmed: account.isStale)
            PctText(pct: pair.window.pct, threshold: context.threshold,
                    font: .system(size: 13, weight: .semibold))
                .frame(width: 50, alignment: .trailing)
        }
    }
}
