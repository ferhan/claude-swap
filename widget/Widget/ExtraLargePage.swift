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
            // The same list as large, cards and all (see `LargeList`).
            VStack(alignment: .leading, spacing: 4) {
                BrandTitle(context: context)
                HStack(spacing: 6) {
                    ListHeader(family: .extraLarge, chunks: chunks, index: index, showsTitle: false)
                    AutoStatusLine(context: context)
                }
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
    var showsTitle = true  // large: the arrows alone, on the auto-switch line

    var body: some View {
        HStack(spacing: 5) {
            if showsTitle {
                Text("ACCOUNTS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
            }
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
/// The design's account card. The badge and the name -- alias and email both
/// -- share the first line; under it one full-width line per window, each with
/// its bar, percent and countdown.
///
/// A fourth line carries the tags -- auth type first -- and the card's own
/// actions, "Switch" (or "Active") and, on large, "Details ›" -- extra-large
/// has no drill-down; a tap on the card selects it for the right column. The
/// actions are an
/// overlay rather than nested buttons -- nesting one `Button(intent:)` inside
/// another's label has no defined winner -- over room the line reserves.
struct SelectableRow: View {
    let account: Account
    let context: PageContext
    let isSelected: Bool
    @Environment(\.widgetRenderingMode) private var mode
    @Environment(\.colorScheme) private var scheme

    private var drills: Bool { context.family == .large }

    var body: some View {
        let accent: Color = mode == .fullColor ? Palette.accent(scheme) : .primary
        selectButton(accent: accent)
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 6) {
                    SwitchControl(account: account, context: context, short: true)
                    if drills { detailsButton(accent: accent) }
                }
                .padding(.trailing, 10).padding(.bottom, 5)
            }
    }

    private func detailsButton(accent: Color) -> some View {
        Button(intent: ShowDetailIntent(family: context.family, number: account.number)) {
            HStack(spacing: 2) {
                Text("Details").font(.system(size: 11, weight: .semibold))
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(accent)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(accent.opacity(0.2)))
            .contentShape(Capsule())
            .widgetAccentable()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Details for \(account.label)")
    }

    private func selectButton(accent: Color) -> some View {
        Button(intent: SelectAccountIntent(family: context.family, number: account.number)) {
            VStack(alignment: .leading, spacing: 3) {
                nameLine(accent: accent)
                if account.usage == nil {
                    Text(account.statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    if let fiveHour = account.usage?.fiveHour {
                        window("5h", fiveHour, ticking: true)
                    }
                    // Always "7d", even when the plan's only weekly limits
                    // are per-model: which model it is belongs to the
                    // detail column, and a name here would cut the bar.
                    if let weekly = account.weeklyWindow?.window {
                        window("7d", weekly, ticking: false)
                    }
                }
                actionLine
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? accent.opacity(0.12) : Color.primary.opacity(0.06)))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? accent : Color.primary.opacity(0.1), lineWidth: isSelected ? 1.5 : 1)
                    .widgetAccentable(isSelected)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .opacity(account.isDisabled ? 0.6 : 1)
        .accessibilityLabel("\(account.fullName)\(isSelected ? ", selected" : "")")
    }

    /// `(W) work — dev@example.com` and the selection chevron. The name is cut
    /// from the tail -- never through the middle, which hid which account it
    /// was.
    private func nameLine(accent: Color) -> some View {
        ViewThatFits(in: .horizontal) {
            line(accent: accent, fixedName: true)
            line(accent: accent, fixedName: false)
        }
    }

    private func line(accent: Color, fixedName: Bool) -> some View {
        HStack(spacing: 7) {
            InitialsBadge(account: account, size: 18)
            Text(account.fullName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .fixedSize(horizontal: fixedName, vertical: false)
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isSelected ? accent : .clear)
                .widgetAccentable()
        }
    }

    /// `OAUTH  NEXT  ◷ 1h ago` on the left, and on the right the room the
    /// Switch and Details overlay sits in. The age goes first when it is tight.
    private var actionLine: some View {
        ViewThatFits(in: .horizontal) {
            actionLine(showsAge: true)
            actionLine(showsAge: false)
        }
    }

    private func actionLine(showsAge: Bool) -> some View {
        HStack(spacing: 6) {
            if let auth = account.authLabel { Tag(text: auth, uppercased: false) }
            tags(showsAge: showsAge)
            Spacer(minLength: 4)
            Color.clear.frame(width: drills ? 150 : 84, height: 20)
        }
    }

    @ViewBuilder private func tags(showsAge: Bool) -> some View {
        if showsAge, account.isStale, let age = account.usageAgeSeconds { AgeLabel(seconds: age) }
        if context.isNext(account) { Tag(text: "Next", accent: true) }
        if account.isDisabled { Tag(text: "Off") }
    }

    /// `5H ▰▰▰▱ 62% 40:28:47`: the ramp bar with its threshold tick, the
    /// percent with its severity glyph, and the countdown (ticking for 5h).
    private func window(_ title: String, _ window: Window, ticking: Bool) -> some View {
        WindowRow(title: title, window: window, threshold: context.threshold,
                  now: context.now, ticking: ticking, dimmed: account.isStale,
                  titleWidth: 30, compact: true)
    }
}

/// The selected account, and what the list rows do not already say: how the
/// week is pacing, and the spend. The 5h/7d bars, percentages and countdowns
/// live in the list cards and are deliberately not repeated, and so is the
/// switch control, which every card carries.
struct SelectedDetail: View {
    let account: Account
    let context: PageContext

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                InitialsBadge(account: account, size: 18)
                AccountTitle(account: account, font: .system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
            }
            if account.usage == nil {
                NoUsage(account: account)
            } else {
                PaceLine(account: account, context: context, kind: .session)
                PaceLine(account: account, context: context)
            }
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
                    .font(.system(size: 11))
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
        HStack(spacing: 7) {
            Text(pair.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 52, alignment: .leading)
            UsageBar(pct: pair.window.pct, threshold: context.threshold, dimmed: account.isStale)
            PctText(pct: pair.window.pct, threshold: context.threshold,
                    font: .system(size: 11, weight: .semibold))
                .frame(width: 44, alignment: .trailing)
        }
    }
}
