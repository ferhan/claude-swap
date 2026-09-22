import XCTest

/// What small's bottom line and medium's right-column bottom line put in the
/// one action spot they each have.
final class CompactActionTests: XCTestCase {
    private func resolve(_ family: LayoutFamily, _ eligibility: SwitchEligibility,
                         stale: Bool = false, auto: Bool = true) -> CompactAction {
        CompactSlot.resolve(family: family, eligibility: eligibility,
                            backendStale: stale, hasAutoswitch: auto)
    }

    /// The green dot beside the name says which account is in use, so the spot
    /// is spent on the auto-switch toggle rather than the word "Active".
    func testTheActiveAccountGetsTheAutoToggleOnBothCompactSizes() {
        XCTAssertEqual(resolve(.small, .active), .auto)
        XCTAssertEqual(resolve(.medium, .active), .auto)
    }

    func testEveryOtherAccountKeepsTheSwitchControl() {
        for eligibility in [SwitchEligibility.eligible, .notSwitchable, .disabled] {
            XCTAssertEqual(resolve(.small, eligibility), .switchAccount, "\(eligibility)")
            XCTAssertEqual(resolve(.medium, eligibility), .switchAccount, "\(eligibility)")
        }
    }

    /// A stopped backend takes the spot on small: nothing else there would be
    /// applied, whatever the account is.
    func testSmallGivesAStoppedBackendTheWholeSpot() {
        for eligibility in [SwitchEligibility.active, .eligible, .notSwitchable, .disabled] {
            XCTAssertEqual(resolve(.small, eligibility, stale: true), .start, "\(eligibility)")
        }
    }

    /// Medium's left column carries the start control, so the spot is left to
    /// the auto chip -- drawn inert -- rather than offering a second start.
    func testMediumLeavesTheStartToItsLeftColumn() {
        for eligibility in [SwitchEligibility.active, .eligible, .notSwitchable, .disabled] {
            XCTAssertEqual(resolve(.medium, eligibility, stale: true), .auto, "\(eligibility)")
        }
    }

    /// A snapshot written before the backend published its auto-switch block:
    /// there is no state to toggle, so the active account keeps the "Active"
    /// marker the switch control draws for it.
    func testWithoutAnAutoswitchBlockTheActiveAccountFallsBackToTheSwitchControl() {
        XCTAssertEqual(resolve(.small, .active, auto: false), .switchAccount)
        XCTAssertEqual(resolve(.medium, .active, auto: false), .switchAccount)
        // Small still offers the start; medium's spot goes empty, its left
        // column already offering the only thing that would help.
        XCTAssertEqual(resolve(.small, .active, stale: true, auto: false), .start)
        XCTAssertEqual(resolve(.medium, .active, stale: true, auto: false), .auto)
    }

    /// The active account is the one page small opens on, so its spot is the
    /// first thing seen: with a live backend that is the toggle.
    func testTheGoldenSnapshotsActivePageOffersTheToggle() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "snapshot_golden",
                                                           withExtension: "json"))
        let snapshot = try Snapshot.decode(Data(contentsOf: url))
        XCTAssertNotNil(snapshot.autoswitch, "the fixture carries the block the toggle needs")
        let actions = try Paging.pages(for: .small, snapshot: snapshot).map { number in
            let account = try XCTUnwrap(snapshot.account(number: number))
            return resolve(.small, account.switchEligibility(activeNumber: snapshot.activeAccountNumber),
                           auto: snapshot.autoswitch != nil)
        }
        // 1 is active, 2 and 3 have a stored login, 4 (api key) has none.
        XCTAssertEqual(actions, [.auto, .switchAccount, .switchAccount, .switchAccount])
        // The backend stopped: every page offers the start instead.
        let stopped = try Paging.pages(for: .small, snapshot: snapshot).map { number in
            let account = try XCTUnwrap(snapshot.account(number: number))
            return resolve(.small, account.switchEligibility(activeNumber: snapshot.activeAccountNumber),
                           stale: true)
        }
        XCTAssertEqual(stopped, [.start, .start, .start, .start])
    }
}
