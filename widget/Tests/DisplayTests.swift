import XCTest

/// Pure display decisions: ramp, severity, formatting, paging.
final class DisplayTests: XCTestCase {
    private func golden() throws -> Snapshot {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "snapshot_golden", withExtension: "json"))
        return try Snapshot.decode(Data(contentsOf: url))
    }

    // MARK: - Ramp and severity

    func testRampIsAnchoredToAbsolutePercentWithRedAtThreshold() {
        let stops = Ramp.stops(threshold: 90)
        XCTAssertEqual(stops.first, RampStop(location: 0, tone: .green))
        XCTAssertEqual(stops.first { $0.tone == .yellow }?.location, 0.5)
        XCTAssertEqual(stops.first { $0.tone == .orange }?.location, 0.7)
        XCTAssertEqual(stops.first { $0.tone == .red }?.location, 0.9)
        XCTAssertEqual(stops.last?.location, 1)
    }

    func testRampStaysOrderedForALowThreshold() {
        for threshold in [0.0, 10, 40, 60, 75, 100, 150] {
            let locations = Ramp.stops(threshold: threshold).map(\.location)
            XCTAssertEqual(locations, locations.sorted(), "threshold \(threshold)")
            XCTAssertTrue(locations.allSatisfy { (0...1).contains($0) }, "threshold \(threshold)")
        }
        XCTAssertEqual(Ramp.stops(threshold: 60).first { $0.tone == .red }?.location, 0.6)
    }

    func testSeverity() {
        XCTAssertEqual(Severity(pct: 69.9, threshold: 90), .normal)
        XCTAssertEqual(Severity(pct: 70, threshold: 90), .warning)
        XCTAssertEqual(Severity(pct: 90, threshold: 90), .critical)
        // A threshold below the warning line: critical wins.
        XCTAssertEqual(Severity(pct: 65, threshold: 60), .critical)
    }

    // MARK: - Formatting

    func testCountdown() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(Format.countdown(to: now.addingTimeInterval(3 * 86_400 + 11 * 3_600 + 59), now: now), "3d 11h")
        XCTAssertEqual(Format.countdown(to: now.addingTimeInterval(5 * 3_600 + 12 * 60), now: now), "5h 12m")
        XCTAssertEqual(Format.countdown(to: now.addingTimeInterval(12 * 60 + 5), now: now), "12m")
        XCTAssertEqual(Format.countdown(to: now.addingTimeInterval(30), now: now), "<1m")
        XCTAssertEqual(Format.countdown(to: now.addingTimeInterval(-5), now: now), "now")
    }

    func testAgeAndPct() {
        XCTAssertEqual(Format.age(seconds: 30), "just now")
        XCTAssertEqual(Format.age(seconds: 90), "1m ago")
        XCTAssertEqual(Format.age(seconds: 3_600), "1h ago")
        XCTAssertEqual(Format.age(seconds: 2 * 86_400), "2d ago")
        XCTAssertEqual(Format.pct(62.5), "62%")
        XCTAssertEqual(Format.pct(99.6), "99%")
        XCTAssertEqual(Format.pct(100), "100%")
    }

    func testInitials() {
        XCTAssertEqual(Format.initials("work"), "W")
        XCTAssertEqual(Format.initials("client-a"), "CA")
        XCTAssertEqual(Format.initials("user@example.com"), "U")
        XCTAssertEqual(Format.initials("first.last@example.com"), "FL")
        XCTAssertEqual(Format.initials("--"), "?")
    }

    func testAccountDisplayFields() throws {
        let snapshot = try golden()
        XCTAssertEqual(snapshot.accounts[0].subtitle, "Example Org")
        XCTAssertEqual(snapshot.accounts[1].subtitle, "personal")
        XCTAssertEqual(snapshot.accounts[3].subtitle, "API key")
        XCTAssertEqual(snapshot.accounts[3].statusText, "Disabled · no usage quota")
        XCTAssertTrue(snapshot.accounts[1].isStale)
        XCTAssertFalse(snapshot.accounts[0].isStale)
        // No 7d aggregate: the compact weekly view falls back to the fullest model.
        XCTAssertEqual(snapshot.accounts[2].weeklyWindow?.title, "Opus")
        XCTAssertEqual(snapshot.accounts[2].windows().map(\.title), ["5h", "Opus", "Sonnet"])
        XCTAssertEqual(snapshot.accounts[2].peakPct, 100)
    }

    /// The extra-large list gives the name a line of its own, so it carries
    /// both halves; an account with no alias is just its email.
    func testFullNameJoinsAliasAndEmail() throws {
        let snapshot = try golden()
        XCTAssertEqual(snapshot.accounts[0].fullName, "work — dev@example.com")
        XCTAssertEqual(snapshot.accounts[1].fullName, snapshot.accounts[1].email)
    }

    /// Per-model windows, and only those: the detail column is the one place
    /// they appear.
    func testScopedWindowsAreTheModelRowsOnly() throws {
        let snapshot = try golden()
        XCTAssertEqual(snapshot.accounts[2].scopedWindows.map(\.title), ["Opus", "Sonnet"])
        XCTAssertTrue(snapshot.accounts[0].scopedWindows.isEmpty)
        XCTAssertTrue(snapshot.accounts[3].scopedWindows.isEmpty)
    }

    // MARK: - Paging

    func testSmallPagesAlternateHeroAndDetail() throws {
        let snapshot = try golden()
        let pages = Paging.pages(for: .small, snapshot: snapshot)
        XCTAssertEqual(pages.count, 8)
        XCTAssertEqual(pages[0], .hero(account: 1))
        XCTAssertEqual(pages[1], .detail(account: 1))
        XCTAssertEqual(Paging.label(for: pages[2], snapshot: snapshot), "2/4")
        XCTAssertEqual(Paging.label(for: pages[1], snapshot: snapshot), "work · details")
    }

    func testMediumOverviewSplitsOthersByThree() throws {
        let snapshot = try golden()
        XCTAssertEqual(Paging.overviewChunks(for: .medium, snapshot: snapshot).map { $0.map(\.number) }, [[2, 3, 4]])
        let pages = Paging.pages(for: .medium, snapshot: snapshot)
        XCTAssertEqual(pages.first, .overview(index: 0, count: 1))
        XCTAssertEqual(pages.count, 5)
        XCTAssertEqual(Paging.label(for: pages[0], snapshot: snapshot), "Overview")
    }

    func testLargeSplitsTheGoldenAccountsAcrossTwoPages() throws {
        // At the legible type sizes two of the golden's cards fill a 344pt page.
        let snapshot = try golden()
        XCTAssertEqual(Paging.overviewChunks(for: .large, snapshot: snapshot).map { $0.map(\.number) },
                       [[1, 2], [3, 4]])
        // Extra-large is master-detail and has no pages at all.
        XCTAssertEqual(Paging.pages(for: .extraLarge, snapshot: snapshot), [])
    }

    /// The golden document with `count` copies of its first account.
    private func golden(copies count: Int) throws -> Snapshot {
        let json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: XCTUnwrap(Bundle(for: Self.self)
                .url(forResource: "snapshot_golden", withExtension: "json")))) as? [String: Any]
        var doc = try XCTUnwrap(json)
        var rows = try XCTUnwrap(doc["accounts"] as? [[String: Any]])
        let first = rows[0]
        rows = (1...count).map { number in
            var row = first
            row["number"] = number
            row["active"] = number == 1
            return row
        }
        doc["accounts"] = rows
        return try Snapshot.decode(JSONSerialization.data(withJSONObject: doc))
    }

    func testLargeSplitsWhenCardsOverflow() throws {
        // Eight copies of the heaviest card cannot share a page.
        let snapshot = try golden(copies: 8)
        XCTAssertEqual(snapshot.accounts.count, 8)
        let chunks = Paging.overviewChunks(for: .large, snapshot: snapshot)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.flatMap { $0 }.count, 8)
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Paging.label(for: .overview(index: 1, count: chunks.count), snapshot: snapshot),
                       "Overview 2/\(chunks.count)")
    }

    // MARK: - Navigation

    func testSelectDrillsDownThenBackReturnsToTheList() {
        let selected = Navigation.select(3, in: NavState(), family: .large)
        XCTAssertEqual(selected, NavState(mode: .detail, selectedAccountNumber: 3, listOffset: 0))
        let back = Navigation.back(selected)
        XCTAssertEqual(back.mode, .list)
        // The list stays where it was.
        XCTAssertEqual(back.listOffset, selected.listOffset)
    }

    func testExtraLargeSelectsInPlace() throws {
        let snapshot = try golden()
        let state = Navigation.select(3, in: NavState(listOffset: 0), family: .extraLarge)
        XCTAssertEqual(state.mode, .list)
        XCTAssertEqual(state.selectedAccountNumber, 3)
        XCTAssertEqual(Navigation.resolve(state, snapshot: snapshot, family: .extraLarge), state)
    }

    func testExtraLargeDefaultsToTheActiveAccount() throws {
        let snapshot = try golden()
        let resolved = Navigation.resolve(NavState(), snapshot: snapshot, family: .extraLarge)
        XCTAssertEqual(resolved.selectedAccountNumber, snapshot.activeAccount?.number)
        XCTAssertEqual(resolved.mode, .list)
    }

    func testVanishedSelectionFallsBack() throws {
        let snapshot = try golden()
        let stale = NavState(mode: .detail, selectedAccountNumber: 42, listOffset: 0)
        let large = Navigation.resolve(stale, snapshot: snapshot, family: .large)
        XCTAssertEqual(large.mode, .list)
        XCTAssertNil(large.selectedAccountNumber)
        let extraLarge = Navigation.resolve(stale, snapshot: snapshot, family: .extraLarge)
        XCTAssertEqual(extraLarge.mode, .list)
        XCTAssertEqual(extraLarge.selectedAccountNumber, 1)
    }

    func testExtraLargeListOverflowsInWindowsOfThree() throws {
        let snapshot = try golden(copies: 9)
        let chunks = Navigation.listChunks(for: .extraLarge, snapshot: snapshot)
        XCTAssertEqual(chunks.map(\.count), [3, 3, 3])
        XCTAssertEqual(Navigation.listChunks(for: .extraLarge, snapshot: try golden()).map(\.count), [3, 1])
    }

    func testScrollMovesByAWindowAndClamps() throws {
        let chunks = Navigation.listChunks(for: .extraLarge, snapshot: try golden(copies: 14))
        XCTAssertEqual(chunks.map(\.count), [3, 3, 3, 3, 2])
        var state = NavState()
        state = Navigation.scroll(state, by: 1, chunks: chunks)
        XCTAssertEqual(state.listOffset, 3)
        state = Navigation.scroll(state, by: 2, chunks: chunks)
        XCTAssertEqual(state.listOffset, 9)
        state = Navigation.scroll(state, by: 3, chunks: chunks)
        XCTAssertEqual(state.listOffset, 12, "clamps at the last window")
        state = Navigation.scroll(state, by: -5, chunks: chunks)
        XCTAssertEqual(state.listOffset, 0, "clamps at the first window")
        state = Navigation.scroll(state, by: -1, chunks: chunks)
        XCTAssertEqual(state.listOffset, 0)
    }

    func testOffsetPastTheRowsSnapsToTheLastWindow() throws {
        // Rows shrank from 14 to 9 while the list was on its third window.
        let snapshot = try golden(copies: 9)
        let resolved = Navigation.resolve(NavState(listOffset: 12), snapshot: snapshot, family: .extraLarge)
        XCTAssertEqual(resolved.listOffset, 6)
        // Mid-window offsets snap to their window's start.
        XCTAssertEqual(Navigation.resolve(NavState(listOffset: 4), snapshot: snapshot,
                                          family: .extraLarge).listOffset, 3)
        XCTAssertEqual(Navigation.resolve(NavState(listOffset: -3), snapshot: snapshot,
                                          family: .extraLarge).listOffset, 0)
    }

    func testNavStateRoundTripsThroughJSON() throws {
        let state = NavState(mode: .detail, selectedAccountNumber: 2, listOffset: 6)
        let decoded = try JSONDecoder().decode(NavState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
    }

}

// Split from the class body only to keep it under the lint length limit.
extension DisplayTests {
    // MARK: - Trend span

    private func snapshot(historyAges ages: [[TimeInterval]], now: Date) throws -> Snapshot {
        let iso = ISO8601DateFormatter()
        let accounts = ages.enumerated().map { index, samples -> String in
            let history = samples.map { #"{"t":"\#(iso.string(from: now.addingTimeInterval(-$0)))","pct":50}"# }
            return """
            {"number":\(index + 1),"email":"a\(index)@example.com","organizationName":"","organizationUuid":"",
             "isOrganization":false,"active":\(index == 0),"kind":"oauth","switchable":true,"usageStatus":"ok",
             "usage":{"fiveHour":{"pct":50,"resetsAt":null,"history":[\(history.joined(separator: ","))]}}}
            """
        }
        let json = """
        {"schemaVersion":1,"takenAt":"\(iso.string(from: now))","activeAccountNumber":1,
         "accounts":[\(accounts.joined(separator: ","))]}
        """
        return try Snapshot.decode(Data(json.utf8))
    }

    func testSpanZoomsToShortHistoryWithAOneHourFloor() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let span = Trend.span(try snapshot(historyAges: [[40 * 60, 60, 0]], now: now), now: now)
        XCTAssertEqual(span.duration, Trend.minSpan)
        XCTAssertEqual(span.covered, 40 * 60)
        XCTAssertEqual(span.caption, "last 40m")
        XCTAssertEqual(span.axisLabels, ["-1h", "-30m", "now"])
    }

    func testSpanFollowsTheOldestSampleAcrossAccounts() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let span = Trend.span(try snapshot(historyAges: [[2 * 3_600], [6 * 3_600, 0]], now: now), now: now)
        XCTAssertEqual(span.start, now.addingTimeInterval(-6 * 3_600))
        XCTAssertEqual(span.caption, "last 6h")
        XCTAssertEqual(span.axisLabels, ["-6h", "-3h", "now"])
    }

    func testSpanCapsAt24h() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // The 30h sample is outside the window; the 23h50m one is the oldest kept.
        let span = Trend.span(try snapshot(historyAges: [[30 * 3_600, 23 * 3_600 + 50 * 60]], now: now), now: now)
        XCTAssertEqual(span.caption, "last 24h")
        XCTAssertEqual(span.axisLabels[1], "-12h")
        // No history at all: the full 24h.
        let empty = Trend.span(try snapshot(historyAges: [[]], now: now), now: now)
        XCTAssertEqual(empty.duration, Trend.maxSpan)
    }

    func testSpanFormatting() {
        XCTAssertEqual(Format.span(seconds: 20), "1m")
        XCTAssertEqual(Format.span(seconds: 40 * 60), "40m")
        XCTAssertEqual(Format.span(seconds: 3_600), "1h")
        XCTAssertEqual(Format.span(seconds: 90 * 60), "1h 30m")
        XCTAssertEqual(Format.span(seconds: 5 * 3_600 + 40 * 60), "5h 40m")
        XCTAssertEqual(Format.span(seconds: 11.6 * 3_600), "12h")
    }

    func testSwitchesWidenTheSpanWithin24h() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let base = try snapshot(historyAges: [[40 * 60, 0]], now: now)
        let iso = ISO8601DateFormatter()
        func at(_ age: TimeInterval) -> String { iso.string(from: now.addingTimeInterval(-age)) }
        // History covers 40m, but the 3h-ago switch pulls the axis back to
        // reach it; the 30h-ago one is past 24h and neither widens nor shows.
        let json = """
        {"schemaVersion":1,"takenAt":"\(at(0))","activeAccountNumber":1,"accounts":[],
         "autoswitch":{"enabled":true,"threshold":90,"nextCandidateNumber":null,
           "switches":[{"at":"\(at(30 * 3_600))","from":1,"to":2},{"at":"\(at(3 * 3_600))","from":1,"to":2},
                       {"at":"\(at(30 * 60))","from":1,"to":2},{"at":"\(at(10 * 60))","from":7,"to":1}]}}
        """
        let events = try Snapshot.decode(Data(json.utf8)).autoswitch
        let merged = Snapshot(schemaVersion: 1, takenAt: now, activeAccountNumber: 1,
                              accounts: base.accounts, autoswitch: events)
        let span = Trend.span(merged, now: now)
        XCTAssertEqual(span.start, now.addingTimeInterval(-3 * 3_600))
        XCTAssertEqual(span.caption, "last 3h")
        let markers = Trend.switchMarkers(merged, now: now)
        XCTAssertEqual(markers.map(\.date), [-3 * 3_600, -30 * 60, -10 * 60].map { now.addingTimeInterval($0) })
        // On the "from" line where it has samples; else on the threshold.
        XCTAssertEqual(markers.map(\.pct), [90, 50, 90])
    }

    func testSwitchesAloneStillGetTheOneHourFloor() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let iso = ISO8601DateFormatter()
        let json = """
        {"schemaVersion":1,"takenAt":"\(iso.string(from: now))","activeAccountNumber":null,"accounts":[],
         "autoswitch":{"enabled":true,"threshold":90,"nextCandidateNumber":null,
           "switches":[{"at":"\(iso.string(from: now.addingTimeInterval(-10 * 60)))","from":1,"to":2}]}}
        """
        let span = Trend.span(try Snapshot.decode(Data(json.utf8)), now: now)
        XCTAssertEqual(span.duration, Trend.minSpan)
        XCTAssertEqual(span.caption, "last 10m")
    }

    // MARK: - Backend staleness

    func testBackendStaleAfterThreeMinutes() throws {
        let snapshot = try golden()
        XCTAssertFalse(snapshot.isBackendStale(now: snapshot.takenAt.addingTimeInterval(180)))
        XCTAssertTrue(snapshot.isBackendStale(now: snapshot.takenAt.addingTimeInterval(181)))
        XCTAssertEqual(Format.backendDown(age: 13 * 60), "Backend stopped · updated 13m ago")
    }

    func testNormalizedWraps() {
        XCTAssertEqual(Paging.normalized(-1, count: 5), 4)
        XCTAssertEqual(Paging.normalized(5, count: 5), 0)
        XCTAssertEqual(Paging.normalized(7, count: 0), 0)
    }
}
