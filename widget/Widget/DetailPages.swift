import SwiftUI
import WidgetKit

// Large's per-account detail view, and the facts grid the large view,
// extra-large and medium all draw.

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

/// Email, org, alias, kind, status and when it was last measured. Shared by
/// the extra-large right column and the large detail view -- both are 318pt
/// wide, so the same four rows fit either way.
///
/// Medium passes `compact`: 147pt of column, so the email moves out to its own
/// full-width line above the grid and the type drops a point and a half. The
/// rows are otherwise the same ones, in the same order.
struct AccountFactsGrid: View {
    let account: Account
    let context: PageContext
    var compact = false

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: compact ? 4 : 6, verticalSpacing: 2) {
            // Email, org and status get the full width and wrap: all
            // three run long, and half a column cut them mid-word.
            if !compact {
                GridRow {
                    key("Email"); value(account.email).gridCellColumns(3)
                }
            }
            GridRow {
                key("Org")
                value(account.organizationName.isEmpty ? "personal" : account.organizationName)
                    .gridCellColumns(3)
            }
            if compact {
                // Two short facts share the row; alias can run long, so it
                // keeps the full width.
                GridRow {
                    key("Alias"); value(account.alias ?? "—").gridCellColumns(3)
                }
                GridRow {
                    key("Kind"); value(account.kind)
                    key("Updated"); value(updated)
                }
                GridRow {
                    key("Status")
                    value(account.active ? "active · \(account.statusText)" : account.statusText)
                        .gridCellColumns(3)
                }
            } else {
                GridRow {
                    key("Alias"); value(account.alias ?? "—")
                    key("Kind"); value(account.kind)
                }
                GridRow {
                    key("Status")
                    value(account.active ? "active · \(account.statusText)" : account.statusText)
                    key("Updated"); value(updated)
                }
            }
        }
        .font(.system(size: compact ? 10 : 11.5))
    }

    private var updated: String {
        account.usageFetchedAt.map { Format.age(seconds: context.now.timeIntervalSince($0)) } ?? "—"
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

/// Large's drill-down: what the extra-large right column shows, stacked for
/// 344pt. "‹ Back" and the switch control share the top line; the 5h/7d bars
/// are deliberately not repeated -- the list row the user just came from
/// carries them -- and neither is the pace strip, which was the first thing
/// dropped to make the chart fit.
struct LargeDetail: View {
    let account: Account
    let context: PageContext

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                BackControl(family: .large)
                Spacer(minLength: 4)
                SwitchControl(account: account, context: context)
            }
            DetailHeader(account: account)
            AccountFactsGrid(account: account, context: context)
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
