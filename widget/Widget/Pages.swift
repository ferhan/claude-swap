import SwiftUI
import WidgetKit

struct CswapWidgetView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    let entry: Entry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot, !snapshot.accounts.isEmpty {
                loaded(snapshot)
            } else {
                EmptyState()
            }
        }
        .padding(family == .small ? 12 : 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Behind everything, across the whole widget rect -- content margins
        // are disabled, so this covers the padding ring too. Without it a tap
        // that misses every control launches the stub host app, whose only
        // window says it is a stub. Real controls sit in front and win the tap.
        .background {
            Button(intent: RefreshIntent()) {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
        }
        .environment(\.largeType, family == .large || family == .extraLarge)
    }

    private var family: LayoutFamily { LayoutFamily(widgetFamily) }

    @ViewBuilder private func loaded(_ snapshot: Snapshot) -> some View {
        if Navigation.usesSelection(family) {
            let context = PageContext(snapshot: snapshot, now: entry.date, family: family, pagerLabel: "",
                                      pendingToggle: entry.pendingToggle, pendingSwitch: entry.pendingSwitch,
                                      backendStartedAt: entry.backendStartedAt,
                                      backendFailure: entry.backendFailure)
            let nav = Navigation.resolve(entry.nav, snapshot: snapshot, family: family)
            switch family {
            case .extraLarge: ExtraLargePage(context: context, nav: nav)
            case .large: LargePage(context: context, nav: nav)
            default: MediumPage(context: context, nav: nav)
            }
        } else {
            let pages = Paging.pages(for: family, snapshot: snapshot)
            let number = pages[Paging.normalized(entry.pageIndex, count: pages.count)]
            let context = PageContext(snapshot: snapshot, now: entry.date, family: family,
                                      pagerLabel: Paging.label(forAccount: number, snapshot: snapshot),
                                      pendingToggle: entry.pendingToggle, pendingSwitch: entry.pendingSwitch,
                                      backendStartedAt: entry.backendStartedAt,
                                      backendFailure: entry.backendFailure)
            SmallPage(context: context, accountNumber: number)
        }
    }
}

/// Everything a page needs besides which page it is.
struct PageContext {
    let snapshot: Snapshot
    let now: Date
    let family: LayoutFamily
    let pagerLabel: String
    var pendingToggle: PendingToggle?
    var pendingSwitch: PendingSwitch?
    var backendStartedAt: Date?
    var backendFailure: BackendStart.FailureNote?

    var threshold: Double { snapshot.threshold }
    var isBackendStale: Bool { snapshot.isBackendStale(now: now) }

    /// The auto-switch toggle's drawn state; nil when the snapshot carries no
    /// auto-switch block to toggle.
    var toggle: ToggleResolution? {
        snapshot.autoswitch.map {
            AutoswitchToggle.resolve(snapshotEnabled: $0.enabled, snapshotStale: isBackendStale,
                                     pending: pendingToggle, now: now)
        }
    }
    var pager: Pager {
        Pager(family: family, label: pagerLabel, dimmed: snapshot.accounts.count < 2)
    }

    var switchState: SwitchState {
        AccountSwitch.resolve(activeNumber: snapshot.activeAccountNumber, pending: pendingSwitch, now: now)
    }

    /// What the Start control draws: a start the host app was asked for
    /// moments ago, or the failure it left behind.
    var startState: BackendStart.StartState {
        BackendStart.state(markerAt: backendStartedAt, failure: backendFailure,
                           snapshotStale: isBackendStale, now: now)
    }

    func isNext(_ account: Account) -> Bool { snapshot.nextCandidate?.number == account.number }
}

struct EmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("ClaudeSwap", systemImage: "arrow.left.arrow.right").font(.headline)
            Text("No snapshot yet. Start cswap to publish usage.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Hero (small, medium left column)

struct HeroHeader: View {
    let account: Account
    var showsActiveDot = false

    var body: some View {
        HStack(spacing: 7) {
            InitialsBadge(account: account, size: 20)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    AccountTitle(account: account)
                    if showsActiveDot && account.active { ActiveMarker(showsText: false) }
                }
                Group {
                    if account.isStale, let age = account.usageAgeSeconds {
                        Text("updated \(Format.age(seconds: age))")
                    } else {
                        Text(account.subtitle)
                    }
                }
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
        }
    }
}

struct HeroGauge: View {
    let account: Account
    let context: PageContext
    /// Medium draws it larger: with the name line gone from that column, the
    /// ring is what the freed height goes to.
    var ringSize: CGFloat = 54

    var body: some View {
        let fiveHour = account.usage?.fiveHour
        HStack(spacing: 10) {
            UsageRing(pct: fiveHour?.pct, threshold: context.threshold,
                      size: ringSize, lineWidth: ringSize > 54 ? 7 : 6, dimmed: account.isStale)
            VStack(alignment: .leading, spacing: 1) {
                Text("RESETS IN")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.secondary)
                if let resetsAt = fiveHour?.resetsAt, resetsAt > context.now {
                    Text(resetsAt, style: .timer)
                        .font(.system(size: 16, weight: .bold).monospacedDigit())
                        .lineLimit(1)
                    Text("at \(resetsAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                } else {
                    Text("—").font(.system(size: 16, weight: .bold))
                }
            }
        }
    }
}

struct HeroWeekly: View {
    let account: Account
    let context: PageContext

    var body: some View {
        if let (title, window) = account.weeklyWindow {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 3) {
                    Text(title).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
                    Spacer(minLength: 2)
                    PctText(pct: window.pct, threshold: context.threshold,
                            font: .system(size: 10, weight: .semibold))
                    if window.aheadOfPace == true {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("ahead of pace")
                    }
                    if let resetsAt = window.resetsAt {
                        Text("· \(Format.countdown(to: resetsAt, now: context.now))")
                            .font(.system(size: 9.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                UsageBar(pct: window.pct, threshold: context.threshold, height: 5, dimmed: account.isStale)
            }
        }
    }
}

/// An account with no usage to draw: API key, expired token, unavailable.
struct NoUsage: View {
    let account: Account
    @Environment(\.largeType) private var largeType

    var body: some View {
        Label(account.statusText, systemImage: account.kind == "api_key" ? "key" : "slash.circle")
            .font(.system(size: largeType ? 12 : 10.5))
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }
}

// MARK: - Small

/// Small is one hero per account: ‹ › walk the logins, with no detail page
/// between them. The green dot beside the name is what says the page is the
/// account in use, so the bottom line spends its 62pt on something to press:
/// the auto-switch toggle on the active account's page, the switch control --
/// in its compact form, with all its states -- on any other, so the page the
/// user is looking at is also the one they can switch to.
struct SmallPage: View {
    let context: PageContext
    let accountNumber: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let account = context.snapshot.account(number: accountNumber) {
                HeroHeader(account: account, showsActiveDot: true)
                Spacer(minLength: 4)
                if account.usage != nil {
                    HeroGauge(account: account, context: context)
                    Spacer(minLength: 4)
                    HeroWeekly(account: account, context: context)
                } else {
                    NoUsage(account: account)
                }
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    CompactActionControl(account: account, context: context)
                    Spacer(minLength: 2)
                    context.pager
                }
            }
        }
    }
}
