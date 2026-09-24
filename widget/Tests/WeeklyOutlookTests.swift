import XCTest

final class WeeklyOutlookTests: XCTestCase {
    private let fetched = Date(timeIntervalSince1970: 1_790_000_000)

    private func weekly(pct: Double, resetsIn: TimeInterval, exhaustion: Date?, willLast: Bool?) -> Window {
        Window(pct: pct, resetsAt: fetched.addingTimeInterval(resetsIn), expectedPct: 98.5, aheadOfPace: false,
               projectedExhaustionAt: exhaustion, willLastToReset: willLast, name: nil, maxed: nil, history: nil)
    }

    /// The live bug: the producer reports an exhausted window's
    /// `projectedExhaustionAt` as its own fetch time, which read as "runs out"
    /// a moment already past. An exhausted window counts down to its reset.
    func testExhaustedWindowCountsDownToResetInsteadOfProjecting() {
        let window = weekly(pct: 100, resetsIn: 2.5 * 3600, exhaustion: fetched, willLast: false)
        XCTAssertTrue(window.isExhausted)
        XCTAssertEqual(window.outlook(now: fetched), .resetsIn(fetched.addingTimeInterval(2.5 * 3600)))
    }

    func testUnexhaustedWindowStillProjects() {
        let runsOut = fetched.addingTimeInterval(3600)
        let window = weekly(pct: 88, resetsIn: 2 * 86400, exhaustion: runsOut, willLast: false)
        XCTAssertFalse(window.isExhausted)
        XCTAssertEqual(window.outlook(now: fetched), .runsOut(runsOut))
        let lasting = weekly(pct: 20, resetsIn: 86400, exhaustion: nil, willLast: true)
        XCTAssertEqual(lasting.outlook(now: fetched), .lastsToReset)
        XCTAssertEqual(weekly(pct: 20, resetsIn: 86400, exhaustion: nil, willLast: nil).outlook(now: fetched), .unknown)
    }

    /// A reset already past while the snapshot still says 100%: "Resetting…",
    /// never a countdown -- a timer to a past date is what took the widget
    /// down.
    func testExhaustedWindowPastItsResetIsResetting() {
        let window = weekly(pct: 100, resetsIn: -60, exhaustion: fetched, willLast: false)
        XCTAssertEqual(window.outlook(now: fetched), .resetting)
    }

    func testFirstHourOfTheWeekIsTooEarlyNotUnknown() {
        let week: TimeInterval = 7 * 86_400
        let early = Window(pct: 3, resetsAt: fetched.addingTimeInterval(week - 1800), expectedPct: nil,
                           aheadOfPace: nil, projectedExhaustionAt: nil, willLastToReset: nil, name: nil,
                           maxed: nil, history: nil)
        XCTAssertTrue(early.isTooEarlyForPace(now: fetched))
        let later = Window(pct: 3, resetsAt: fetched.addingTimeInterval(week - 4 * 3600), expectedPct: nil,
                           aheadOfPace: nil, projectedExhaustionAt: nil, willLastToReset: nil, name: nil,
                           maxed: nil, history: nil)
        XCTAssertFalse(later.isTooEarlyForPace(now: fetched))  // missing past the floor: really unknown
    }

    /// 14% used 5h in: not 15 points over expected, but the projection runs
    /// out before the reset -- the label says ahead, agreeing with RUNS OUT.
    func testRunningOutBeforeResetReadsAheadOfPace() {
        let projecting = weekly(pct: 14, resetsIn: 6 * 86400, exhaustion: fetched.addingTimeInterval(86400),
                                willLast: false)
        XCTAssertEqual(projecting.aheadOfPace, false)
        XCTAssertEqual(projecting.isAheadOfPace, true)
        XCTAssertEqual(weekly(pct: 10, resetsIn: 6 * 86400, exhaustion: nil, willLast: true).isAheadOfPace, false)
        XCTAssertNil(Window(pct: 10, resetsAt: nil, expectedPct: nil, aheadOfPace: nil, projectedExhaustionAt: nil,
                            willLastToReset: nil, name: nil, maxed: nil, history: nil).isAheadOfPace)
    }

    func testExpectedPctRoundsToNearest() {
        XCTAssertEqual(Format.expectedPct(2.9), "3%")
        XCTAssertEqual(Format.expectedPct(2.4), "2%")
        XCTAssertEqual(Format.pct(2.9), "2%")  // usage still rounds down
    }
}
