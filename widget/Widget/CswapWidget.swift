import SwiftUI
import WidgetKit

struct Entry: TimelineEntry {
    let date: Date
    let snapshot: Snapshot?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now, snapshot: SnapshotFile.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // One entry: every time-varying thing on screen is a `Text(date:style:)`
        // driven by an absolute `resetsAt`, so WidgetKit ticks the countdowns
        // itself and later entries would only re-render the same numbers. The
        // reload is what picks up a newer snapshot file.
        // 60s matches the backend's own poll interval: asking for less would
        // only re-read a file that cannot have changed. WidgetKit budgets
        // reloads and may serve them less often than requested -- this is the
        // ceiling, not a guarantee.
        let entry = Entry(date: .now, snapshot: SnapshotFile.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(60))))
    }
}

/// `pct` as the menu bar prints it, and the marker that goes after it.
private struct WindowLabel: View {
    let title: String
    let window: Window

    var body: some View {
        HStack(spacing: 3) {
            Text("\(title) \(window.pct, format: .number.precision(.fractionLength(0)))%")
            switch window.marker {
            case .maxed:
                Text("(!)").foregroundStyle(.red)
            case .aheadOfPace:
                Text("(ahead)").foregroundStyle(.orange)
            case .none:
                EmptyView()
            }
        }
        .lineLimit(1)
    }
}

/// The windows of one account, in the order the menu bar lists them.
private func windowLabels(_ usage: Usage) -> [(String, Window)] {
    var out: [(String, Window)] = []
    if let window = usage.fiveHour { out.append(("5h", window)) }
    if let window = usage.sevenDay { out.append(("7d", window)) }
    for window in usage.scoped ?? [] {
        out.append((window.name ?? "", window))
    }
    return out
}

/// The soonest reset across an account's windows. Absolute, so the countdown
/// is derived here rather than read from the snapshot's stale `countdown`.
private func nextReset(_ usage: Usage) -> Date? {
    windowLabels(usage).compactMap { $0.1.resetsAt }.min()
}

private struct AccountRow: View {
    let account: Account

    var body: some View {
        HStack(spacing: 6) {
            Text(account.active ? "●" : "○")
                .foregroundStyle(account.active ? Color.accentColor : .secondary)
            Text(account.label)
                .fontWeight(account.active ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let usage = account.usage {
                ForEach(Array(windowLabels(usage).enumerated()), id: \.offset) { _, pair in
                    WindowLabel(title: pair.0, window: pair.1)
                }
            } else {
                Text(account.usageStatus.replacingOccurrences(of: "_", with: " "))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .opacity(account.isDisabled ? 0.5 : 1)
    }
}

struct CswapWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let snapshot = entry.snapshot {
                loaded(snapshot)
            } else {
                Text("cswap").font(.headline)
                Text("No snapshot yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func loaded(_ snapshot: Snapshot) -> some View {
        if family == .systemSmall {
            small(snapshot)
        } else {
            ForEach(snapshot.accounts, id: \.number) { account in
                AccountRow(account: account)
            }
        }
    }

    @ViewBuilder
    private func small(_ snapshot: Snapshot) -> some View {
        let account = snapshot.accounts.first { $0.active } ?? snapshot.accounts.first
        if let account {
            Text(account.label)
                .font(.headline)
                .lineLimit(1)
            if let usage = account.usage {
                ForEach(Array(windowLabels(usage).enumerated()), id: \.offset) { _, pair in
                    WindowLabel(title: pair.0, window: pair.1)
                        .font(.caption)
                }
                if let reset = nextReset(usage) {
                    Text(reset, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(account.usageStatus.replacingOccurrences(of: "_", with: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct CswapWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CswapWidget", provider: Provider()) { entry in
            CswapWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("cswap")
        .description("Claude account usage at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
