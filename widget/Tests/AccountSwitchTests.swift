import XCTest

/// "Switch to this account": the request file, eligibility, and pending-state
/// resolution.
final class AccountSwitchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_891_428.123)

    // MARK: - Request encoding

    func testRequestEncodesTheContract() throws {
        let data = try SwitchRequest(to: 3, at: now).encoded()
        XCTAssertEqual(String(bytes: data, encoding: .utf8),
                       #"{"at":"2026-09-20T08:03:48Z","switch":{"to":3}}"#)
    }

    func testFileNameCarriesEpochMillis() {
        XCTAssertEqual(SwitchRequest.fileName(at: now), "switch-1789891428123.json")
    }

    func testWriteRenamesIntoPlaceAndLeavesNoTemp() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try SwitchRequest.write(to: 2, at: now, into: dir)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path),
                       ["switch-1789891428123.json"])
        XCTAssertEqual(try Data(contentsOf: url), try SwitchRequest(to: 2, at: now).encoded())
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testWriteRefusesAMissingDropDirectory() {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        XCTAssertThrowsError(try SwitchRequest.write(to: 2, at: now, into: dir)) {
            XCTAssertEqual($0 as? RequestDrop.WriteError, .noDropDirectory)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "must not create the directory")
    }

    // MARK: - Eligibility

    private func account(number: Int, active: Bool = false, switchable: Bool = true,
                         disabled: Bool = false, kind: String = "oauth") throws -> Account {
        let json = """
        {"number": \(number), "email": "a\(number)@example.com", "organizationName": "",
         "organizationUuid": "", "isOrganization": false, "active": \(active), "kind": "\(kind)",
         "switchable": \(switchable), "usageStatus": "ok"\(disabled ? #", "disabled": true"# : "")}
        """
        return try JSONDecoder().decode(Account.self, from: Data(json.utf8))
    }

    func testActiveAccountIsNotOffered() throws {
        XCTAssertEqual(try account(number: 1, active: true).switchEligibility(activeNumber: 1), .active)
        // activeAccountNumber alone is enough, whatever the row's flag says.
        XCTAssertEqual(try account(number: 1).switchEligibility(activeNumber: 1), .active)
    }

    func testAccountWithoutABackupIsNotSwitchable() throws {
        XCTAssertEqual(try account(number: 2, switchable: false).switchEligibility(activeNumber: 1), .notSwitchable)
    }

    func testDisabledIsNotOffered() throws {
        // The backend refuses a widget switch to a disabled slot
        // (`apply_switch_request`), so offering it would only ever end in
        // "Switch not applied".
        XCTAssertEqual(try account(number: 2, disabled: true).switchEligibility(activeNumber: 1), .disabled)
        // No backup either: that is the plainer reason, so it is the one shown.
        XCTAssertEqual(try account(number: 2, switchable: false, disabled: true)
            .switchEligibility(activeNumber: 1), .notSwitchable)
    }

    func testAPIKeySlotWithABackupStaysAnExplicitTarget() throws {
        XCTAssertEqual(try account(number: 3, kind: "api_key").switchEligibility(activeNumber: 1), .eligible)
        XCTAssertEqual(try account(number: 4).switchEligibility(activeNumber: nil), .eligible)
    }

    // MARK: - Pending resolution

    private func resolve(active: Int?, _ pending: PendingSwitch?, after seconds: TimeInterval) -> SwitchState {
        AccountSwitch.resolve(activeNumber: active, pending: pending, now: now.addingTimeInterval(seconds))
    }

    func testDeliveredRequestShowsSwitchingUntilTheSnapshotAgrees() {
        let pending = PendingSwitch(target: 3, requestedAt: now, delivered: true)
        XCTAssertEqual(resolve(active: 1, pending, after: 2), .switching(target: 3))
        XCTAssertEqual(resolve(active: 3, pending, after: 2), .idle)
    }

    /// `SwitchAccountIntent` returns without waiting for the backend (see
    /// `AutoswitchToggleTests`): the reload it asks for runs against a
    /// snapshot that still has the old account active, and must already draw
    /// "Switching…".
    func testSwitchingShowsAtOnceWithNoTimeForTheBackend() {
        let pending = PendingSwitch(target: 3, requestedAt: now, delivered: true)
        XCTAssertEqual(resolve(active: 1, pending, after: 0), .switching(target: 3))
    }

    func testTimeoutShowsNotAppliedThenClears() {
        let pending = PendingSwitch(target: 3, requestedAt: now, delivered: true)
        XCTAssertEqual(resolve(active: 1, pending, after: 29.9), .switching(target: 3))
        XCTAssertEqual(resolve(active: 1, pending, after: 30), .notApplied(target: 3))
        XCTAssertEqual(resolve(active: 1, pending, after: 60), .idle)
        // Applied late: the snapshot wins even during "not applied".
        XCTAssertEqual(resolve(active: 3, pending, after: 45), .idle)
    }

    func testUndeliveredRequestIsNotAppliedAtOnce() {
        let pending = PendingSwitch(target: 2, requestedAt: now, delivered: false)
        XCTAssertEqual(resolve(active: 1, pending, after: 1), .notApplied(target: 2))
        XCTAssertEqual(resolve(active: 1, pending, after: 30), .idle)
    }

    func testNoRequestIsIdle() {
        XCTAssertEqual(resolve(active: 1, nil, after: 0), .idle)
    }

    func testExpiryWalksTheStates() {
        let pending = PendingSwitch(target: 3, requestedAt: now, delivered: true)
        XCTAssertEqual(AccountSwitch.expiry(of: pending, now: now.addingTimeInterval(5)), now.addingTimeInterval(30))
        XCTAssertEqual(AccountSwitch.expiry(of: pending, now: now.addingTimeInterval(35)), now.addingTimeInterval(60))
        XCTAssertNil(AccountSwitch.expiry(of: pending, now: now.addingTimeInterval(60)))
        let failed = PendingSwitch(target: 3, requestedAt: now, delivered: false)
        XCTAssertEqual(AccountSwitch.expiry(of: failed, now: now), now.addingTimeInterval(30))
        XCTAssertNil(AccountSwitch.expiry(of: nil, now: now))
    }

    func testPendingRoundTripsThroughJSON() throws {
        let pending = PendingSwitch(target: 4, requestedAt: now, delivered: true)
        XCTAssertEqual(try JSONDecoder().decode(PendingSwitch.self, from: JSONEncoder().encode(pending)), pending)
    }
}
