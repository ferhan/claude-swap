import XCTest

/// The consumer half of the `cswap snapshot` schema contract.
///
/// The producer is `src/claude_swap/snapshot_json.py`, and
/// `tests/test_snapshot_json.py::test_snapshot_matches_the_committed_golden_fixture`
/// asserts it against the same committed file this decodes:
/// `tests/fixtures/snapshot_golden.json`, bundled here as a test resource
/// rather than copied, so there is exactly one fixture and it cannot drift.
///
/// If this suite fails, the Python side moved: a field was renamed, dropped,
/// retyped, or changed between present/absent. Fix both halves together.
final class SnapshotGoldenTests: XCTestCase {
    private var snapshot: Snapshot!

    override func setUpWithError() throws {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "snapshot_golden", withExtension: "json"),
            "snapshot_golden.json is not in the test bundle -- check the resources build phase"
        )
        snapshot = try Snapshot.decode(Data(contentsOf: url))
    }

    // MARK: - Both timestamp formats

    /// The document mixes second-precision `...Z` with raw API passthrough
    /// carrying six fractional digits and a numeric offset. No single
    /// `ISO8601DateFormatter` option set reads both.
    func testBothTimestampFormatsParse() {
        XCTAssertEqual(SnapshotDate.parse("2026-09-20T10:03:48Z")?.timeIntervalSince1970,
                       1_789_898_628.0)
        let fractional = SnapshotDate.parse("2026-09-23T21:33:43.377897+00:00")
        XCTAssertEqual(try XCTUnwrap(fractional).timeIntervalSince1970,
                       1_790_199_223.377897, accuracy: 0.000_01,
                       "six fractional digits must survive the parse")
        XCTAssertNil(SnapshotDate.parse("not a date"))
    }

    func testDocumentLevelFields() {
        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertEqual(snapshot.takenAt.timeIntervalSince1970, 1_789_898_628.0)
        XCTAssertEqual(snapshot.activeAccountNumber, 1)
        XCTAssertEqual(snapshot.accounts.map(\.number), [1, 2, 3, 4])
    }

    // MARK: - Account 1: pace present, spend, alias, active

    func testAccountOne() throws {
        let account = snapshot.accounts[0]
        XCTAssertEqual(account.number, 1)
        XCTAssertEqual(account.email, "dev@example.com")
        XCTAssertEqual(account.organizationName, "Example Org")
        XCTAssertEqual(account.organizationUuid, "00000000-0000-4000-8000-000000000001")
        XCTAssertTrue(account.isOrganization)
        XCTAssertTrue(account.active)
        XCTAssertEqual(account.kind, "oauth")
        XCTAssertTrue(account.switchable)
        XCTAssertEqual(account.usageStatus, "ok")
        XCTAssertEqual(account.alias, "work")
        XCTAssertEqual(account.label, "work")
        XCTAssertNil(account.disabled)
        XCTAssertFalse(account.isDisabled)
        XCTAssertEqual(account.usageFetchedAt?.timeIntervalSince1970, 1_789_898_538.0)
        XCTAssertEqual(account.usageAgeSeconds, 90.0)

        let usage = try XCTUnwrap(account.usage)
        XCTAssertNil(usage.scoped)

        let fiveHour = try XCTUnwrap(usage.fiveHour)
        XCTAssertEqual(fiveHour.pct, 62.5)
        XCTAssertEqual(try XCTUnwrap(fiveHour.resetsAt).timeIntervalSince1970,
                       1_789_911_223.377897, accuracy: 0.000_01)
        // Pace fields are weekly-only; the 5h window never carries them.
        XCTAssertNil(fiveHour.expectedPct)
        XCTAssertNil(fiveHour.aheadOfPace)
        XCTAssertNil(fiveHour.projectedExhaustionAt)
        XCTAssertNil(fiveHour.willLastToReset)
        // `name`/`maxed` exist on scoped windows only.
        XCTAssertNil(fiveHour.name)
        XCTAssertNil(fiveHour.maxed)
        XCTAssertEqual(fiveHour.marker, .none)

        let sevenDay = try XCTUnwrap(usage.sevenDay)
        XCTAssertEqual(sevenDay.pct, 88.0)
        XCTAssertEqual(try XCTUnwrap(sevenDay.resetsAt).timeIntervalSince1970,
                       1_790_199_223.377897, accuracy: 0.000_01)
        XCTAssertEqual(sevenDay.expectedPct, 50.3)
        XCTAssertEqual(sevenDay.aheadOfPace, true)
        XCTAssertEqual(sevenDay.projectedExhaustionAt?.timeIntervalSince1970, 1_789_940_008.0)
        XCTAssertEqual(sevenDay.willLastToReset, false)
        XCTAssertNil(sevenDay.name)
        XCTAssertNil(sevenDay.maxed)
        XCTAssertEqual(sevenDay.marker, .aheadOfPace)

        let spend = try XCTUnwrap(usage.spend)
        XCTAssertEqual(spend.used, 12.5)
        XCTAssertEqual(spend.limit, 300.0)
        XCTAssertEqual(spend.pct, 4.2)
        XCTAssertEqual(spend.currency, "USD")
        XCTAssertEqual(spend.resetsAt?.timeIntervalSince1970, 1_790_812_800.0)
    }

    // MARK: - Account 2: pace ABSENT, personal account

    func testAccountTwoHasNoPaceFieldsAtAll() throws {
        let account = snapshot.accounts[1]
        XCTAssertEqual(account.email, "second@example.com")
        XCTAssertEqual(account.organizationName, "")
        // Empty string, never null -- personal accounts have no org UUID.
        XCTAssertEqual(account.organizationUuid, "")
        XCTAssertFalse(account.isOrganization)
        XCTAssertFalse(account.active)
        XCTAssertNil(account.alias)
        XCTAssertEqual(account.label, "second@example.com")
        XCTAssertNil(account.disabled)
        XCTAssertEqual(account.usageFetchedAt?.timeIntervalSince1970, 1_789_895_028.0)
        XCTAssertEqual(account.usageAgeSeconds, 3600.0)

        let usage = try XCTUnwrap(account.usage)
        let fiveHour = try XCTUnwrap(usage.fiveHour)
        XCTAssertEqual(fiveHour.pct, 5.0)
        XCTAssertEqual(try XCTUnwrap(fiveHour.resetsAt).timeIntervalSince1970,
                       1_789_908_492.114530, accuracy: 0.000_01)

        let sevenDay = try XCTUnwrap(usage.sevenDay)
        XCTAssertEqual(sevenDay.pct, 12.0)
        XCTAssertEqual(try XCTUnwrap(sevenDay.resetsAt).timeIntervalSince1970,
                       1_790_478_228.512345, accuracy: 0.000_01)
        // The keys are MISSING, not null and not false: pace was not
        // computable. nil means "unknown", which must not render as "on pace".
        XCTAssertNil(sevenDay.expectedPct)
        XCTAssertNil(sevenDay.aheadOfPace)
        XCTAssertNil(sevenDay.projectedExhaustionAt)
        XCTAssertNil(sevenDay.willLastToReset)
        XCTAssertEqual(sevenDay.marker, .none)

        XCTAssertNil(usage.spend)
        XCTAssertNil(usage.scoped)
    }

    // MARK: - Account 3: scoped windows, maxed outranks aheadOfPace

    func testAccountThreeScopedWindows() throws {
        let account = snapshot.accounts[2]
        XCTAssertEqual(account.email, "third@example.com")
        XCTAssertEqual(account.organizationName, "Example Team")
        XCTAssertEqual(account.organizationUuid, "00000000-0000-4000-8000-000000000003")
        XCTAssertTrue(account.isOrganization)
        XCTAssertEqual(account.usageAgeSeconds, 120.0)
        XCTAssertEqual(account.usageFetchedAt?.timeIntervalSince1970, 1_789_898_508.0)

        let usage = try XCTUnwrap(account.usage)
        XCTAssertEqual(try XCTUnwrap(usage.fiveHour).pct, 41.0)
        // No weekly aggregate at all on this row -- only per-model windows.
        XCTAssertNil(usage.sevenDay)
        XCTAssertNil(usage.spend)

        let scoped = try XCTUnwrap(usage.scoped)
        XCTAssertEqual(scoped.map(\.name), ["Opus", "Sonnet"])

        let opus = scoped[0]
        XCTAssertEqual(opus.pct, 100.0)
        XCTAssertEqual(try XCTUnwrap(opus.resetsAt).timeIntervalSince1970,
                       1_790_237_700.240921, accuracy: 0.000_01)
        XCTAssertEqual(opus.expectedPct, 43.9)
        XCTAssertEqual(opus.projectedExhaustionAt?.timeIntervalSince1970, 1_789_898_508.0)
        XCTAssertEqual(opus.willLastToReset, false)
        // Both true at once. `maxed` wins, matching `usage_summary` in
        // src/claude_swap/menubar.py: "(!)" before "(ahead)".
        XCTAssertEqual(opus.maxed, true)
        XCTAssertEqual(opus.aheadOfPace, true)
        XCTAssertEqual(opus.marker, .maxed)

        let sonnet = scoped[1]
        XCTAssertEqual(sonnet.pct, 30.0)
        XCTAssertEqual(sonnet.expectedPct, 43.9)
        XCTAssertEqual(sonnet.projectedExhaustionAt?.timeIntervalSince1970, 1_790_518_259.0)
        XCTAssertEqual(sonnet.willLastToReset, true)
        // Explicitly false -- distinct from account 2's absent key.
        XCTAssertEqual(sonnet.maxed, false)
        XCTAssertEqual(sonnet.aheadOfPace, false)
        XCTAssertEqual(sonnet.marker, .none)
    }

    // MARK: - Account 4: sentinel row

    func testAccountFourIsASentinelRow() {
        let account = snapshot.accounts[3]
        XCTAssertEqual(account.email, "apikey@example.com")
        XCTAssertEqual(account.organizationName, "")
        XCTAssertEqual(account.organizationUuid, "")
        XCTAssertFalse(account.isOrganization)
        XCTAssertEqual(account.kind, "api_key")
        XCTAssertFalse(account.switchable)
        XCTAssertEqual(account.usageStatus, "api_key")
        XCTAssertNil(account.usage)
        XCTAssertEqual(account.disabled, true)
        XCTAssertTrue(account.isDisabled)
        // No measurement, so no freshness fields are emitted for this row.
        XCTAssertNil(account.usageFetchedAt)
        XCTAssertNil(account.usageAgeSeconds)
        XCTAssertNil(account.alias)
    }
}
