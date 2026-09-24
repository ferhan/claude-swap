import SwiftUI
import WidgetKit

// Large's per-account detail view.

// MARK: - Detail

struct DetailHeader: View {
    let account: Account
    @Environment(\.largeType) private var largeType

    var body: some View {
        HStack(spacing: 7) {
            InitialsBadge(account: account, size: 20)
            VStack(alignment: .leading, spacing: 0) {
                AccountTitle(account: account, font: .system(size: 12, weight: .semibold))
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

/// Large's drill-down: what the extra-large right column shows, stacked for
/// 344pt, under "‹ Back". The switch control and the 5h/7d bars are
/// deliberately not repeated -- the card the user just came from carries
/// them. The pace, the models and the trend share the rest; the trend takes
/// whatever height is left.
struct LargeDetail: View {
    let account: Account
    let context: PageContext

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            BackControl(family: .large)
            DetailHeader(account: account)
            if account.usage == nil {
                NoUsage(account: account)
            } else {
                PaceLine(account: account, context: context)
            }
            Divider()
            ModelUsagePanel(account: account, context: context)
            Divider()
            TrendPanel(context: context, emphasized: account.number, compact: true)
        }
    }
}

/// "‹ Back": the account list again, with the account still selected. No
/// next/prev -- the list is one tap away and shows where the account sits.
struct BackControl: View {
    let family: LayoutFamily

    var body: some View {
        Button(intent: BackToListIntent(family: family)) {
            ActionChip(title: "Back", symbol: "chevron.left")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to the account list")
    }
}
