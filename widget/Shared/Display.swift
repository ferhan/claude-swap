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
    /// Points over expected-by-now that count as ahead of pace: the
    /// backend's `AHEAD_THRESHOLD_PCT`, used here for the 5h session, which
    /// the backend does not pace.
    static let aheadThresholdPct = 15.0
    /// The 5h window's length.
    static let sessionPeriod: TimeInterval = 5 * 3_600
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

/// What a pace panel shows for one window: a verdict and, when there is one,
/// where usage is expected to be by now.
struct PaceReading: Equatable {
    enum Verdict: Equatable { case atLimit, ahead, onPace, tooEarly, unknown, noSession }
    let verdict: Verdict
    let expectedPct: Double?
}

extension Window {
    /// The weekly window: the producer's pace fields, read as `isAheadOfPace`.
    func weeklyReading(now: Date) -> PaceReading {
        if isExhausted { return PaceReading(verdict: .atLimit, expectedPct: nil) }
        let verdict: PaceReading.Verdict = switch isAheadOfPace {
        case true?: .ahead
        case false?: .onPace
        case nil: isTooEarlyForPace(now: now) ? .tooEarly : .unknown
        }
        return PaceReading(verdict: verdict, expectedPct: expectedPct)
    }

    /// The 5h session, which the producer does not pace: expected-by-now is
    /// elapsed / 5h, from a start of `resetsAt` - 5h. Ahead is used minus
    /// expected over the same 15 points the weekly marker uses -- there is no
    /// run-out projection here to judge by. No `resetsAt`, or one already
    /// past: no session running.
    func sessionReading(now: Date) -> PaceReading {
        if isExhausted { return PaceReading(verdict: .atLimit, expectedPct: nil) }
        guard let resetsAt, resetsAt > now else { return PaceReading(verdict: .noSession, expectedPct: nil) }
        let period = Display.sessionPeriod
        let elapsed = min(max(period - resetsAt.timeIntervalSince(now), 0), period)
        let expected = elapsed / period * 100
        let ahead = pct - expected >= Display.aheadThresholdPct
        return PaceReading(verdict: ahead ? .ahead : .onPace, expectedPct: expected)
    }
}

/// What the pace panel says about the rest of a weekly window.
enum WeeklyOutlook: Equatable {
    /// At the limit: nothing left to project, only the wait for the reset.
    case resetsIn(Date)
    /// At the limit with the reset already past: the next snapshot will show
    /// the new week. Never a countdown to a moment behind us.
    case resetting
    /// The producer's linear projection, before the reset.
    case runsOut(Date)
    case lastsToReset
    case unknown
}

extension Window {
    /// At the limit: the producer's own `maxed` rule (`pct >= 100`, see
    /// `snapshot_json.py`), applied to any window.
    var isExhausted: Bool { pct >= 100 }

    /// The pace panel's verdict: ahead when the producer flags it, and also
    /// whenever the projection says the week runs out before its reset -- so
    /// the label never says "on pace" beside a red "runs out". Nil: unknown.
    var isAheadOfPace: Bool? {
        if aheadOfPace == true || willLastToReset == false { return true }
        return aheadOfPace
    }

    /// Under an hour into the week: the producer publishes no pace then
    /// (`SUPPRESS_AFTER_RESET_S` in `pace.py`, mirrored here), so missing
    /// pace fields mean "too early", not missing data.
    func isTooEarlyForPace(now: Date) -> Bool {
        guard aheadOfPace == nil, let resetsAt else { return false }
        let week: TimeInterval = 7 * 86_400
        let remaining = resetsAt.timeIntervalSince(now).truncatingRemainder(dividingBy: week)
        let elapsed = week - (remaining < 0 ? remaining + week : remaining)
        return elapsed < 3_600
    }

    /// An exhausted window never shows a run-out time: the producer reports
    /// its `projectedExhaustionAt` as the fetch time, a moment already past,
    /// which read as a future "runs out".
    func outlook(now: Date) -> WeeklyOutlook {
        if isExhausted {
            guard let resetsAt else { return .unknown }
            return resetsAt > now ? .resetsIn(resetsAt) : .resetting
        }
        if willLastToReset == false, let runsOut = projectedExhaustionAt { return .runsOut(runsOut) }
        if willLastToReset == true { return .lastsToReset }
        return .unknown
    }
}

/// What the hero's "RESETS IN" counts down to.
enum ResetTarget: Equatable {
    /// `weekly`: the 7d window is the binding one, so the caption says so.
    case countdown(Date, weekly: Bool)
    /// The binding reset is already behind us; the next snapshot catches up.
    case resetting
    case none
}

extension Usage {
    /// The reset that makes the account usable again. With nothing exhausted
    /// that is the 5h reset, as it always was. Otherwise the exhausted
    /// windows' (5h, 7d) resets, and of those the LATER one -- the account is
    /// blocked until every exhausted limit has reset.
    func resetTarget(now: Date) -> ResetTarget {
        let windows: [(window: Window?, weekly: Bool)] = [(fiveHour, false), (sevenDay, true)]
        let exhausted = windows.filter { $0.window?.isExhausted == true }
        let candidates = (exhausted.isEmpty ? [windows[0]] : exhausted)
            .compactMap { pair in pair.window?.resetsAt.map { (date: $0, weekly: pair.weekly) } }
        guard let target = candidates.max(by: { $0.date < $1.date }) else { return .none }
        return target.date > now ? .countdown(target.date, weekly: target.weekly) : .resetting
    }
}

extension Account {
    /// `Example Org`, `personal` or `API key` -- the line under the label.
    var subtitle: String {
        if kind == "api_key" { return "API key" }
        return organizationName.isEmpty ? "personal" : organizationName
    }

    /// The large card's auth-type tag: `OAuth` or `API Key`; nil for a kind
    /// the widget does not know, rather than a guess.
    var authLabel: String? {
        switch kind {
        case "oauth": "OAuth"
        case "api_key": "API Key"
        default: nil
        }
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

    /// `work — dev@example.com`, or just the email when the slot has no
    /// alias. The extra-large list gives this a line of its own so neither
    /// half is cut.
    var fullName: String {
        guard let alias, !alias.isEmpty, alias != email else { return email }
        return "\(alias) — \(email)"
    }

    /// The per-model weekly windows, in the producer's order. Only the
    /// extra-large detail column shows these.
    var scopedWindows: [(title: String, window: Window)] {
        (usage?.scoped ?? []).prefix(Display.maxScopedRows).map { ($0.name ?? "Model", $0) }
    }

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

    /// Expected-by-now, to the nearest whole percent: a target, not a limit,
    /// so 2.9 reads "3%".
    static func expectedPct(_ value: Double) -> String { "\(Int(value.rounded()))%" }

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
        "Backend stopped · updated \(age(seconds: seconds))"
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

enum Paging {
    /// Small is the one size left that pages, and its pages are the accounts:
    /// one hero each, in display order, so ‹ › walks the logins and nothing
    /// else. Every other size keeps a selection instead (see `Navigation`).
    static func pages(for family: LayoutFamily, snapshot: Snapshot) -> [Int] {
        guard family == .small else { return [] }
        return snapshot.orderedAccounts.map(\.number)
    }

    static func normalized(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index % count) + count) % count
    }

    /// The text between ‹ and ›.
    static func label(forAccount number: Int, snapshot: Snapshot) -> String {
        let accounts = snapshot.orderedAccounts
        let position = (accounts.firstIndex { $0.number == number } ?? 0) + 1
        return "\(position)/\(accounts.count)"
    }
}
