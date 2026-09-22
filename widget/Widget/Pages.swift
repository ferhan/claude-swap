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
        .environment(\.largeType, family == .large || family == .extraLarge)
    }

    private var family: LayoutFamily { LayoutFamily(widgetFamily) }

    @ViewBuilder private func loaded(_ snapshot: Snapshot) -> some View {
        if family == .extraLarge {
            ExtraLargePage(
                context: PageContext(snapshot: snapshot, now: entry.date, family: family, pagerLabel: "",
                                     pendingToggle: entry.pendingToggle),
                nav: Navigation.resolve(entry.nav, snapshot: snapshot, family: family))
        } else {
            let pages = Paging.pages(for: family, snapshot: snapshot)
            let page = pages[Paging.normalized(entry.pageIndex, count: pages.count)]
            let context = PageContext(snapshot: snapshot, now: entry.date, family: family,
                                      pagerLabel: Paging.label(for: page, snapshot: snapshot),
                                      pendingToggle: entry.pendingToggle)
            switch family {
            case .small: SmallPage(context: context, page: page)
            case .medium: MediumPage(context: context, page: page)
            case .large, .extraLarge: LargePage(context: context, page: page)
            }
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
    var pager: Pager { Pager(family: family, label: pagerLabel) }

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

    var body: some View {
        let fiveHour = account.usage?.fiveHour
        HStack(spacing: 10) {
            UsageRing(pct: fiveHour?.pct, threshold: context.threshold, dimmed: account.isStale)
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

struct SmallPage: View {
    let context: PageContext
    let page: Page

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch page {
            case .hero(let number):
                if let account = context.snapshot.account(number: number) {
                    HeroHeader(account: account)
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
                        if account.active {
                            ActiveMarker()
                        } else if context.isNext(account) {
                            Tag(text: "Next up")
                        }
                        Spacer(minLength: 2)
                        context.pager
                    }
                }
            case .detail(let number):
                if let account = context.snapshot.account(number: number) {
                    DetailHeader(account: account)
                    Spacer(minLength: 3)
                    DetailFacts(account: account, context: context, compact: true)
                    Spacer(minLength: 3)
                    DetailWindows(account: account, context: context, limit: 2, titleWidth: 28, compact: true)
                    Spacer(minLength: 3)
                    context.pager
                }
            case .overview:
                EmptyView()
            }
        }
    }
}

// MARK: - Medium

struct MediumPage: View {
    let context: PageContext
    let page: Page

    var body: some View {
        switch page {
        case .overview(let index, _):
            let chunks = Paging.overviewChunks(for: .medium, snapshot: context.snapshot)
            let others = chunks.indices.contains(index) ? chunks[index] : []
            let hero = context.snapshot.activeAccount ?? context.snapshot.orderedAccounts[0]
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    HeroHeader(account: hero, showsActiveDot: true)
                    Spacer(minLength: 4)
                    if hero.usage != nil {
                        HeroGauge(account: hero, context: context)
                        Spacer(minLength: 4)
                        HeroWeekly(account: hero, context: context)
                    } else {
                        NoUsage(account: hero)
                    }
                    Spacer(minLength: 4)
                    context.pager
                }
                .frame(width: 150)
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("OTHER ACCOUNTS")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        AutoBadge(snapshot: context.snapshot)
                    }
                    if others.isEmpty {
                        Spacer()
                        Text("No other accounts").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    } else {
                        ForEach(others, id: \.number) { account in
                            Spacer(minLength: 3)
                            CompactRow(account: account, context: context)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        case .detail(let number):
            if let account = context.snapshot.account(number: number) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 0) {
                        DetailHeader(account: account)
                        Spacer(minLength: 4)
                        DetailFacts(account: account, context: context, compact: false)
                        Spacer(minLength: 4)
                        context.pager
                    }
                    .frame(width: 150)
                    Divider()
                    VStack(alignment: .leading, spacing: 7) {
                        Text("USAGE WINDOWS")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                        DetailWindows(account: account, context: context, limit: 4, titleWidth: 36)
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        case .hero:
            EmptyView()
        }
    }
}

/// `⇄ Auto at 90%` / `Auto off`; nothing when the snapshot predates it.
struct AutoBadge: View {
    let snapshot: Snapshot

    var body: some View {
        if let auto = snapshot.autoswitch {
            Label(auto.enabled ? "Auto at \(Format.pct(auto.threshold))" : "Auto off",
                  systemImage: auto.enabled ? "arrow.left.arrow.right" : "pause.circle")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

struct CompactRow: View {
    let account: Account
    let context: PageContext

    var body: some View {
        HStack(spacing: 7) {
            InitialsBadge(account: account, size: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    // The subtitle goes first when space runs out, rather
                    // than leaving a one-letter stub.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 4) {
                            AccountTitle(account: account, font: .system(size: 11, weight: .semibold))
                                .fixedSize()
                            Text(account.subtitle)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                        AccountTitle(account: account, font: .system(size: 11, weight: .semibold))
                    }
                    Spacer(minLength: 2)
                    if context.isNext(account) { Tag(text: "Next") }
                }
                if account.usage != nil {
                    HStack(spacing: 8) {
                        ForEach(Array(account.windows(maxScoped: 1).prefix(2).enumerated()), id: \.offset) { _, pair in
                            HStack(spacing: 3) {
                                Text(pair.title).font(.system(size: 9.5)).foregroundStyle(.secondary)
                                    .lineLimit(1).fixedSize()
                                PctText(pct: pair.window.pct, threshold: context.threshold,
                                        font: .system(size: 10, weight: .semibold))
                            }
                        }
                        if account.isStale, let age = account.usageAgeSeconds { AgeLabel(seconds: age) }
                    }
                } else {
                    Text(account.statusText)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .opacity(account.isDisabled ? 0.6 : 1)
    }
}
