import SwiftUI
import WidgetKit

// The per-account detail page, in its small, medium and large forms.

// MARK: - Detail

struct DetailHeader: View {
    let account: Account
    @Environment(\.largeType) private var largeType

    var body: some View {
        HStack(spacing: 7) {
            InitialsBadge(account: account, size: 20)
            VStack(alignment: .leading, spacing: 0) {
                AccountTitle(account: account)
                HStack(spacing: 4) {
                    if account.active { ActiveMarker(showsText: false) }
                    Text(account.active ? "active · \(account.statusText)" : account.statusText)
                }
                .font(.system(size: largeType ? 11 : 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }
}

struct DetailFacts: View {
    let account: Account
    let context: PageContext
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 1 : 3) {
            fact("envelope", account.email)
            if let alias = account.alias, !compact { fact("tag", "alias \(alias)") }
            if compact {
                fact("person", "\(account.subtitle) · \(account.kind)")
            } else {
                fact("person", account.subtitle)
                fact("key", "kind \(account.kind)")
            }
            if let fetched = account.usageFetchedAt {
                fact("clock", "updated \(Format.age(seconds: context.now.timeIntervalSince(fetched)))")
            }
        }
        .font(.system(size: compact ? 9 : 9.5))
        .foregroundStyle(.secondary)
    }

    private func fact(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).frame(width: 10)
            Text(text).lineLimit(1).truncationMode(.middle)
        }
    }
}

struct DetailWindows: View {
    let account: Account
    let context: PageContext
    let limit: Int
    let titleWidth: CGFloat
    var compact = false

    var body: some View {
        let windows = account.windows()
        VStack(alignment: .leading, spacing: 5) {
            if windows.isEmpty {
                NoUsage(account: account)
            }
            ForEach(Array(windows.prefix(limit).enumerated()), id: \.offset) { _, pair in
                WindowRow(title: pair.title, window: pair.window, threshold: context.threshold,
                          now: context.now, ticking: pair.title == "5h", dimmed: account.isStale,
                          titleWidth: titleWidth, compact: compact)
            }
            if windows.count > limit {
                Text("+\(windows.count - limit) more on larger sizes")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct LargeDetail: View {
    let account: Account
    let context: PageContext

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                DetailHeader(account: account)
                Spacer(minLength: 4)
                SwitchControl(account: account, context: context)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                row("Email", account.email)
                row("Alias", account.alias ?? "—")
                row("Organization", account.organizationName.isEmpty ? "personal" : account.organizationName)
                row("Kind", account.kind)
                row("Usage status", account.usageStatus)
                if let fetched = account.usageFetchedAt {
                    row("Last updated",
                        "\(fetched.formatted(date: .abbreviated, time: .shortened)) · "
                            + Format.age(seconds: context.now.timeIntervalSince(fetched)))
                }
            }
            .font(.system(size: 12))
            Text("USAGE WINDOWS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            DetailWindows(account: account, context: context, limit: .max, titleWidth: 44)
            if let spend = account.usage?.spend {
                Text("Spend \(spend.used.formatted(.currency(code: spend.currency))) / "
                     + spend.limit.formatted(.currency(code: spend.currency)))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func row(_ key: String, _ value: String) -> some View {
        GridRow {
            Text(key).foregroundStyle(.secondary)
            Text(value).lineLimit(1).truncationMode(.middle)
        }
    }
}
