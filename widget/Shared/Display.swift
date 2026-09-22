import Foundation

// Pure display logic: everything the views decide that is not drawing. Kept
// free of SwiftUI/WidgetKit so the test target can exercise it directly.

enum Display {
    /// Used when the snapshot carries no `autoswitch` block.
    static let defaultThreshold = 90.0
    /// Absolute percent at which a window is flagged as a warning.
    static let warningPct = 70.0
    /// A measurement older than this is drawn dimmed with its age beside it.
    static let staleAfterSeconds = 600.0
    /// A snapshot older than this means the backend is not republishing it:
    /// the backend polls every 60s, so three missed polls.
    static let backendStaleAfterSeconds = 180.0
    /// Model-scoped rows shown per account card.
    static let maxScopedRows = 4
}

extension Snapshot {
    /// The red stop of every ramp and the critical cut-off.
    var threshold: Double { autoswitch?.threshold ?? Display.defaultThreshold }

    /// Active account first, then by slot number: the order every page uses.
    var orderedAccounts: [Account] {
        accounts.sorted { lhs, rhs in
            if lhs.active != rhs.active { return lhs.active }
            return lhs.number < rhs.number
        }
    }

    var activeAccount: Account? { accounts.first { $0.active } }

    func account(number: Int) -> Account? { accounts.first { $0.number == number } }

    /// The backend has stopped republishing: the whole snapshot is old, not
    /// just one account's measurement.
    func isBackendStale(now: Date) -> Bool {
        now.timeIntervalSince(takenAt) > Display.backendStaleAfterSeconds
    }

    /// The backend's next switch target, when it published one.
    var nextCandidate: Account? {
        autoswitch?.nextCandidateNumber.flatMap { account(number: $0) }
    }
}

extension Account {
    /// `Example Org`, `personal` or `API key` -- the line under the label.
    var subtitle: String {
        if kind == "api_key" { return "API key" }
        return organizationName.isEmpty ? "personal" : organizationName
    }

    /// Why there is no usage, in words. `usageStatus` is a machine string.
    var statusText: String {
        let reason: String
        switch usageStatus {
        case "ok": reason = "ok"
        case "api_key": reason = "no usage quota"
        case "token_expired": reason = "token expired"
        case "unavailable": reason = "usage unavailable"
        default: reason = usageStatus.replacingOccurrences(of: "_", with: " ")
        }
        return isDisabled ? "Disabled · \(reason)" : reason
    }

    var isStale: Bool { (usageAgeSeconds ?? 0) > Display.staleAfterSeconds }

    /// `W` for `work`, `CA` for `client-a`, `U` for `user@example.com`.
    var initials: String { Format.initials(label) }

    /// The weekly window the compact views show: the aggregate when there is
    /// one, else the fullest per-model window (some plans have only those).
    var weeklyWindow: (title: String, window: Window)? {
        guard let usage else { return nil }
        if let sevenDay = usage.sevenDay { return ("Weekly", sevenDay) }
        if let worst = usage.scoped?.max(by: { $0.pct < $1.pct }) {
            return (worst.name ?? "Weekly", worst)
        }
        return nil
    }

    /// Every window, in the menu bar's order: 5h, 7d, then per-model.
    func windows(maxScoped: Int = .max) -> [(title: String, window: Window)] {
        guard let usage else { return [] }
        var out: [(String, Window)] = []
        if let window = usage.fiveHour { out.append(("5h", window)) }
        if let window = usage.sevenDay { out.append(("7d", window)) }
        for window in (usage.scoped ?? []).prefix(maxScoped) {
            out.append((window.name ?? "Model", window))
        }
        return out
    }

    /// The highest percentage across all windows, for "(12% used)".
    var peakPct: Double? { windows().map(\.window.pct).max() }
}

// MARK: - Severity and color ramp

enum Severity: Int, Comparable, Sendable {
    case normal, warning, critical

    init(pct: Double, threshold: Double) {
        if pct >= threshold {
            self = .critical
        } else if pct >= Display.warningPct {
            self = .warning
        } else {
            self = .normal
        }
    }

    static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum Tone: Sendable, Equatable {
    case green, yellow, orange, red
}

struct RampStop: Sendable, Equatable {
    let location: Double
    let tone: Tone
}

/// A fixed ramp anchored to absolute percent across the whole track, so a
/// given percentage is always the same color regardless of how full the bar
/// is. The views size the gradient to the full track and clip it to the fill.
enum Ramp {
    static func stops(threshold: Double) -> [RampStop] {
        let red = min(max(threshold / 100, 0.05), 1)
        let orange = min(0.70, red - 0.05)
        let yellow = min(0.50, orange - 0.10)
        let raw: [RampStop] = [
            .init(location: 0, tone: .green),
            .init(location: yellow - 0.15, tone: .green),
            .init(location: yellow, tone: .yellow),
            .init(location: orange, tone: .orange),
            .init(location: red, tone: .red),
            .init(location: 1, tone: .red)
        ]
        // A low threshold squeezes the lower stops below zero; keep the list
        // non-decreasing and inside 0...1, which is all a gradient needs.
        var floor = 0.0
        return raw.map { stop in
            floor = max(floor, min(max(stop.location, 0), 1))
            return RampStop(location: floor, tone: stop.tone)
        }
    }
}

// MARK: - Formatting

enum Format {
    /// Whole percent, rounded down: 99.6 is not yet "100%".
    static func pct(_ value: Double) -> String { "\(Int(value.rounded(.down)))%" }

    /// A human, non-ticking countdown: `3d 11h`, `5h 12m`, `12m`, `<1m`.
    static func countdown(to date: Date, now: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return "now" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }

    /// `just now`, `5m ago`, `1h ago`, `2d ago`.
    static func age(seconds: Double) -> String {
        let secs = Int(max(seconds, 0))
        if secs < 60 { return "just now" }
        if secs < 3_600 { return "\(secs / 60)m ago" }
        if secs < 86_400 { return "\(secs / 3_600)h ago" }
        return "\(secs / 86_400)d ago"
    }

    /// The header's cue for a snapshot nobody is republishing.
    static func backendDown(age seconds: Double) -> String {
        "Backend not running · updated \(age(seconds: seconds))"
    }

    /// A duration for the trend's caption and axis: `40m`, `1h 30m`, `6h`.
    /// Ten hours and up round to the hour; below that minutes still matter.
    static func span(seconds: Double) -> String {
        let minutes = Int((max(seconds, 0) / 60).rounded())
        if minutes < 60 { return "\(max(minutes, 1))m" }
        if minutes >= 600 { return "\(Int((Double(minutes) / 60).rounded()))h" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    static func initials(_ label: String) -> String {
        let base = label.split(separator: "@").first.map(String.init) ?? label
        let parts = base
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { !$0.isEmpty }
        let letters = parts.prefix(2).compactMap(\.first)
        guard !letters.isEmpty else { return "?" }
        return String(letters).uppercased()
    }
}

// MARK: - Paging

/// Size classes the widget lays out for, mirrored from `WidgetFamily` so the
/// paging logic stays testable without WidgetKit.
enum LayoutFamily: String, Sendable, CaseIterable {
    case small, medium, large, extraLarge
}

enum Page: Equatable, Sendable {
    /// Small: one account's hero.
    case hero(account: Int)
    /// Medium/large/extra-large: the overview, split when it does not fit.
    case overview(index: Int, count: Int)
    /// Any size: one account's detail.
    case detail(account: Int)
}

enum Paging {
    /// Compact rows beside the medium hero.
    static let mediumRowsPerPage = 3
    /// Large/extra-large card budget, in bar-row units (see `cardWeight`).
    static let largeBudget = 13.0

    /// Overview first (or one hero per account on small), then one detail
    /// page per account, so ‹ › reaches everything.
    static func pages(for family: LayoutFamily, snapshot: Snapshot) -> [Page] {
        let accounts = snapshot.orderedAccounts
        switch family {
        case .small:
            return accounts.flatMap { [Page.hero(account: $0.number), .detail(account: $0.number)] }
        case .extraLarge:
            // Master-detail, no pager: see `Navigation`.
            return []
        case .medium, .large:
            let count = overviewChunks(for: family, snapshot: snapshot).count
            return (0..<count).map { Page.overview(index: $0, count: count) }
                + accounts.map { .detail(account: $0.number) }
        }
    }

    /// The accounts on each overview page: the non-active ones beside the
    /// medium hero, every account as a card on large/extra-large.
    static func overviewChunks(for family: LayoutFamily, snapshot: Snapshot) -> [[Account]] {
        let accounts = snapshot.orderedAccounts
        switch family {
        case .small:
            return [accounts]
        case .medium:
            let others = accounts.filter { !$0.active }
            guard !others.isEmpty else { return [[]] }
            return stride(from: 0, to: others.count, by: mediumRowsPerPage).map {
                Array(others[$0..<min($0 + mediumRowsPerPage, others.count)])
            }
        case .large, .extraLarge:
            var chunks: [[Account]] = []
            var current: [Account] = []
            var used = 0.0
            for account in accounts {
                let weight = cardWeight(account)
                if !current.isEmpty && used + weight > largeBudget {
                    chunks.append(current)
                    current = []
                    used = 0
                }
                current.append(account)
                used += weight
            }
            if !current.isEmpty || chunks.isEmpty { chunks.append(current) }
            return chunks
        }
    }

    /// A card's height in bar rows: header plus spacing, then one per window
    /// (or the status line, when there are none) and one for the
    /// ahead-of-pace note.
    static func cardWeight(_ account: Account) -> Double {
        let rows = max(account.windows(maxScoped: Display.maxScopedRows).count, 1)
        let paceNote = account.usage?.sevenDay?.aheadOfPace == true ? 1 : 0
        return 2.2 + Double(rows + paceNote)
    }

    static func normalized(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index % count) + count) % count
    }

    /// The text between ‹ and ›.
    static func label(for page: Page, snapshot: Snapshot) -> String {
        switch page {
        case .hero(let number):
            let accounts = snapshot.orderedAccounts
            let position = (accounts.firstIndex { $0.number == number } ?? 0) + 1
            return "\(position)/\(accounts.count)"
        case .overview(let index, let count):
            return count > 1 ? "Overview \(index + 1)/\(count)" : "Overview"
        case .detail(let number):
            return "\(snapshot.account(number: number)?.label ?? "#\(number)") · details"
        }
    }
}

// MARK: - 24h trend

enum Trend {
    /// The most history the chart ever shows (and the producer ever keeps).
    static let maxSpan: TimeInterval = 24 * 3_600
    /// The narrowest time axis: less than this and a few samples would be
    /// stretched into a misleadingly steep line.
    static let minSpan: TimeInterval = 3_600

    /// Samples inside the last 24h, oldest first.
    static func points(_ history: [HistoryPoint]?, now: Date) -> [HistoryPoint] {
        let start = now.addingTimeInterval(-maxSpan)
        return (history ?? [])
            .filter { $0.time >= start && $0.time <= now }
            .sorted { $0.time < $1.time }
    }

    /// Linear interpolation between the samples around `date`; nil outside.
    static func value(at date: Date, in points: [HistoryPoint]) -> Double? {
        guard let first = points.first, let last = points.last,
              date >= first.time, date <= last.time else { return nil }
        guard let upper = points.firstIndex(where: { $0.time >= date }) else { return nil }
        let right = points[upper]
        if upper == 0 || right.time == date { return right.pct }
        let left = points[upper - 1]
        let span = right.time.timeIntervalSince(left.time)
        guard span > 0 else { return right.pct }
        let fraction = date.timeIntervalSince(left.time) / span
        return left.pct + (right.pct - left.pct) * fraction
    }

    /// True when any account has something to draw.
    static func hasData(_ snapshot: Snapshot, now: Date) -> Bool {
        snapshot.accounts.contains { !points($0.usage?.fiveHour?.history, now: now).isEmpty }
    }

    /// The chart's time axis. It spans the data actually held rather than a
    /// fixed 24h, so a backend that started 40 minutes ago draws a readable
    /// line instead of a sliver at the right edge.
    struct Span: Equatable, Sendable {
        /// Left edge of the axis: the oldest sample or switch, widened to `minSpan`.
        let start: Date
        let end: Date
        /// How much history there is, which can be less than the axis.
        let covered: TimeInterval

        var duration: TimeInterval { end.timeIntervalSince(start) }

        /// `last 40m`, `last 6h`, `last 24h`.
        var caption: String { "last \(Format.span(seconds: covered))" }

        /// Left, middle and right axis hints, relative to now.
        var axisLabels: [String] {
            ["-\(Format.span(seconds: duration))", "-\(Format.span(seconds: duration / 2))", "now"]
        }
    }

    /// From the oldest thing worth drawing -- a sample or an auto-switch --
    /// within the last 24h, to now, at least `minSpan` wide. With neither it
    /// is the full 24h (the chart then says so anyway).
    static func span(_ snapshot: Snapshot, now: Date) -> Span {
        let window = now.addingTimeInterval(-maxSpan)...now
        let oldestSample = snapshot.accounts
            .compactMap { points($0.usage?.fiveHour?.history, now: now).first?.time }
            .min()
        let oldestSwitch = (snapshot.autoswitch?.switches ?? []).map(\.date).filter(window.contains).min()
        let dataStart = [oldestSample, oldestSwitch].compactMap { $0 }.min() ?? window.lowerBound
        let start = min(dataStart, now.addingTimeInterval(-minSpan))
        return Span(start: start, end: now, covered: now.timeIntervalSince(dataStart))
    }

    struct Marker: Equatable, Sendable {
        let date: Date
        let pct: Double
    }

    /// Where each switch sits on the chart: on the line of the account it
    /// switched away from, else on the threshold it presumably crossed.
    /// Clipped to the visible span.
    static func switchMarkers(_ snapshot: Snapshot, now: Date) -> [Marker] {
        let start = span(snapshot, now: now).start
        return (snapshot.autoswitch?.switches ?? [])
            .filter { $0.date >= start && $0.date <= now }
            .map { event in
                let history = points(snapshot.account(number: event.fromNumber)?.usage?.fiveHour?.history, now: now)
                return Marker(date: event.date, pct: value(at: event.date, in: history) ?? snapshot.threshold)
            }
    }
}
