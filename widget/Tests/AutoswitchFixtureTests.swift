import XCTest

/// The additive `autoswitch` block and 5h `history`, decoded from a
/// hand-written fixture matching the contract (the Python producer does not
/// emit them yet, so the golden fixture cannot cover them).
final class AutoswitchFixtureTests: XCTestCase {
    private var snapshot: Snapshot!

    override func setUpWithError() throws {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "snapshot_autoswitch", withExtension: "json"),
            "snapshot_autoswitch.json is not in the test bundle"
        )
        snapshot = try Snapshot.decode(Data(contentsOf: url))
    }

    private func date(_ text: String) -> Date { SnapshotDate.parse(text)! }

    func testAutoswitchBlock() throws {
        let auto = try XCTUnwrap(snapshot.autoswitch)
        XCTAssertTrue(auto.enabled)
        XCTAssertEqual(auto.threshold, 85)
        XCTAssertEqual(auto.nextCandidateNumber, 3)
        XCTAssertEqual(auto.switches?.count, 2)
        XCTAssertEqual(auto.switches?.first?.fromNumber, 1)
        XCTAssertEqual(auto.switches?.first?.toNumber, 2)
        XCTAssertEqual(auto.switches?.first?.date, date("2026-09-20T06:00:00Z"))

        XCTAssertEqual(snapshot.threshold, 85)
        XCTAssertEqual(snapshot.nextCandidate?.number, 3)
    }

    func testNullNextCandidateDecodes() throws {
        let json = """
        {"schemaVersion":1,"takenAt":"2026-09-20T10:03:48Z","activeAccountNumber":null,
         "accounts":[],"autoswitch":{"enabled":false,"threshold":90,"nextCandidateNumber":null}}
        """
        let decoded = try Snapshot.decode(Data(json.utf8))
        XCTAssertNil(decoded.autoswitch?.nextCandidateNumber)
        XCTAssertNil(decoded.autoswitch?.switches)
        XCTAssertNil(decoded.nextCandidate)
    }

    func testHistoryDecodes() throws {
        let history = try XCTUnwrap(snapshot.accounts[0].usage?.fiveHour?.history)
        XCTAssertEqual(history.count, 4)
        XCTAssertEqual(history.first, HistoryPoint(time: date("2026-09-19T08:00:00Z"), pct: 10))
        // Empty list and absent key are both "nothing to draw".
        XCTAssertEqual(snapshot.accounts[1].usage?.fiveHour?.history?.count, 0)
        XCTAssertNil(snapshot.accounts[2].usage?.fiveHour?.history)
    }

    func testTrendDropsSamplesOlderThan24h() {
        let points = Trend.points(snapshot.accounts[0].usage?.fiveHour?.history, now: snapshot.takenAt)
        XCTAssertEqual(points.map(\.pct), [70, 90, 86])
        XCTAssertTrue(Trend.hasData(snapshot, now: snapshot.takenAt))
    }

    func testSwitchMarkerSitsOnTheFromAccountsLine() {
        // 06:00 is halfway between 04:00 (70%) and 08:00 (90%); the 09-18
        // switch is outside the 24h window and dropped.
        let markers = Trend.switchMarkers(snapshot, now: snapshot.takenAt)
        XCTAssertEqual(markers, [Trend.Marker(date: date("2026-09-20T06:00:00Z"), pct: 80)])
    }

    func testOrderingPutsActiveFirst() {
        XCTAssertEqual(snapshot.orderedAccounts.map(\.number), [2, 1, 3])
        XCTAssertEqual(snapshot.activeAccount?.number, 2)
    }
}
