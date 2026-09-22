import Foundation

// The 24h 5h-usage trend the extra-large chart draws: which samples are in
// range, the time axis they span, and where the auto-switches sit on it.

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
