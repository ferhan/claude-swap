import XCTest

final class SessionPaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func fiveHour(_ pct: Double, resetsIn: TimeInterval?) -> Window {
        Window(pct: pct, resetsAt: resetsIn.map { now.addingTimeInterval($0) }, expectedPct: nil,
               aheadOfPace: nil, projectedExhaustionAt: nil, willLastToReset: nil, name: nil, maxed: nil,
               history: nil)
    }

    /// 2h into a 5h session (resets in 3h): 40% expected by now.
    func testExpectedIsElapsedOverFiveHours() throws {
        let reading = fiveHour(30, resetsIn: 3 * 3600).sessionReading(now: now)
        XCTAssertEqual(try XCTUnwrap(reading.expectedPct), 40, accuracy: 0.001)
        XCTAssertEqual(reading.verdict, .onPace)  // 10 points over: under the 15-point bar
    }

    func testFifteenPointsOverExpectedIsAhead() {
        XCTAssertEqual(fiveHour(55, resetsIn: 3 * 3600).sessionReading(now: now).verdict, .ahead)
        XCTAssertEqual(fiveHour(54, resetsIn: 3 * 3600).sessionReading(now: now).verdict, .onPace)
    }

    func testNoResetsAtIsNoSession() {
        let reading = fiveHour(0, resetsIn: nil).sessionReading(now: now)
        XCTAssertEqual(reading, PaceReading(verdict: .noSession, expectedPct: nil))
        XCTAssertEqual(fiveHour(20, resetsIn: -60).sessionReading(now: now).verdict, .noSession)
    }

    func testExhaustedSessionIsAtLimit() {
        XCTAssertEqual(fiveHour(100, resetsIn: 3600).sessionReading(now: now).verdict, .atLimit)
    }
}
