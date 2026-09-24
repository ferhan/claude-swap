import XCTest

final class ResetTargetTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func window(_ pct: Double, resetsIn: TimeInterval?) -> Window {
        Window(pct: pct, resetsAt: resetsIn.map { now.addingTimeInterval($0) }, expectedPct: nil,
               aheadOfPace: nil, projectedExhaustionAt: nil, willLastToReset: nil, name: nil, maxed: nil,
               history: nil)
    }

    private func usage(fiveHour: Window?, sevenDay: Window?) -> Usage {
        Usage(fiveHour: fiveHour, sevenDay: sevenDay, spend: nil, scoped: nil)
    }

    /// The live case: 7d at 100%, an idle 5h window with no reset at all.
    /// "RESETS IN" had nothing to count down to; it counts to the 7d reset.
    func testExhaustedWeekCountsDownToTheWeeklyReset() {
        let target = usage(fiveHour: window(0, resetsIn: nil), sevenDay: window(100, resetsIn: 2 * 3600))
            .resetTarget(now: now)
        XCTAssertEqual(target, .countdown(now.addingTimeInterval(2 * 3600), weekly: true))
    }

    func testExhaustedWeekOutranksTheSoonerFiveHourReset() {
        let target = usage(fiveHour: window(40, resetsIn: 1800), sevenDay: window(100, resetsIn: 7200))
            .resetTarget(now: now)
        XCTAssertEqual(target, .countdown(now.addingTimeInterval(7200), weekly: true))
    }

    func testBothExhaustedCountsToTheLaterReset() {
        let fiveLater = usage(fiveHour: window(100, resetsIn: 9000), sevenDay: window(100, resetsIn: 7200))
        XCTAssertEqual(fiveLater.resetTarget(now: now), .countdown(now.addingTimeInterval(9000), weekly: false))
        let weekLater = usage(fiveHour: window(100, resetsIn: 1800), sevenDay: window(100, resetsIn: 7200))
        XCTAssertEqual(weekLater.resetTarget(now: now), .countdown(now.addingTimeInterval(7200), weekly: true))
    }

    func testNothingExhaustedKeepsTheFiveHourReset() {
        let target = usage(fiveHour: window(40, resetsIn: 1800), sevenDay: window(88, resetsIn: 86400))
            .resetTarget(now: now)
        XCTAssertEqual(target, .countdown(now.addingTimeInterval(1800), weekly: false))
        XCTAssertEqual(usage(fiveHour: window(0, resetsIn: nil), sevenDay: nil).resetTarget(now: now), .none)
    }

    func testPastResetIsResetting() {
        let target = usage(fiveHour: nil, sevenDay: window(100, resetsIn: -60)).resetTarget(now: now)
        XCTAssertEqual(target, .resetting)
    }
}
