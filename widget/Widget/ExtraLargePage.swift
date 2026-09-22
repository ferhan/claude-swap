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
            .frame(width: 300)
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

/// `ACCOUNTS   ▲ 1–6 of 9 ▼`. The arrows appear only when the list overflows.
struct ListHeader: View {
    let family: LayoutFamily
    let chunks: [[Account]]
    let index: Int

    var body: some View {
        HStack(spacing: 5) {
            Text("ACCOUNTS")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if chunks.count > 1 {
                let start = Navigation.chunkStart(index, chunks: chunks)
                let total = chunks.reduce(0) { $0 + $1.count }
                arrow(delta: -1, symbol: "chevron.up", name: "Previous accounts", enabled: index > 0)
                Text("\(start + 1)–\(start + chunks[index].count) of \(total)")
                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                arrow(delta: 1, symbol: "chevron.down", name: "More accounts", enabled: index < chunks.count - 1)
            }
        }
        .frame(height: 18)
    }

    private func arrow(delta: Int, symbol: String, name: String, enabled: Bool) -> some View {
        Button(intent: ScrollListIntent(family: family, delta: delta)) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .bold))
                .frame(width: 18, height: 18)
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
struct SelectableRow: View {
    let account: Account
    let context: PageContext
    let isSelected: Bool
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        let accent: Color = mode == .fullColor ? .accentColor : .primary
        Button(intent: SelectAccountIntent(family: context.family, number: account.number)) {
            HStack(spacing: 7) {
                InitialsBadge(account: account, size: 20)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        // The subtitle goes before the name is cut short.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 4) {
                                title.fixedSize()
                                Text(account.subtitle)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                            }
                            title
                        }
                        Spacer(minLength: 2)
                        if account.isStale, let age = account.usageAgeSeconds { AgeLabel(seconds: age) }
                        if context.isNext(account) { Tag(text: "Next") }
                        if account.isDisabled { Tag(text: "Off") }
                        if account.active { ActiveMarker(showsText: false) }
                    }
                    if account.usage != nil {
                        HStack(spacing: 10) {
                            if let fiveHour = account.usage?.fiveHour {
                                MiniWindow(title: "5h", window: fiveHour, account: account, context: context)
                            }
                            if let (title, window) = account.weeklyWindow {
                                MiniWindow(title: title == "Weekly" ? "7d" : title, window: window,
                                           account: account, context: context)
                            }
                        }
                    } else {
                        Text(account.statusText)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isSelected ? accent : .clear)
                    .widgetAccentable()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? accent.opacity(0.16) : Color.primary.opacity(0.04)))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10).stroke(accent, lineWidth: 1).widgetAccentable()
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .opacity(account.isDisabled ? 0.6 : 1)
        .accessibilityLabel("\(account.label)\(isSelected ? ", selected" : "")")
    }

    private var title: some View {
        AccountTitle(account: account, font: .system(size: 11.5, weight: .semibold))
    }
}

/// `5h ▰▰▱ 62%` -- a label, a short bar and the percent, for list rows.
struct MiniWindow: View {
    let title: String
    let window: Window
    let account: Account
    let context: PageContext

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            UsageBar(pct: window.pct, threshold: context.threshold, height: 4, dimmed: account.isStale)
            PctText(pct: window.pct, threshold: context.threshold, font: .system(size: 9.5, weight: .semibold))
        }
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
            .font(.system(size: 10))
            if windows.isEmpty {
                NoUsage(account: account)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(Array(stride(from: 0, to: windows.count, by: 2)), id: \.self) { start in
                        GridRow {
                            ForEach(windows[start..<min(start + 2, windows.count)].indices, id: \.self) { index in
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
                  titleWidth: 34, compact: true)
    }

    private func key(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).lineLimit(1).fixedSize()
    }

    private func value(_ text: String) -> some View {
        Text(text).lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
