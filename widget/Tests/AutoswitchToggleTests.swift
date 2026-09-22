import XCTest

/// The auto-switch toggle's request file and pending-state resolution.
final class AutoswitchToggleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_891_428.123)

    // MARK: - Request encoding

    func testRequestEncodesTheContract() throws {
        let data = try AutoswitchRequest(enabled: false, at: now).encoded()
        XCTAssertEqual(String(bytes: data, encoding: .utf8),
                       #"{"at":"2026-09-20T08:03:48Z","autoswitch":{"enabled":false}}"#)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((object["autoswitch"] as? [String: Any])?["enabled"] as? Bool, false)
        XCTAssertNotNil(SnapshotDate.parse(try XCTUnwrap(object["at"] as? String)))
    }

    func testFileNamesCarryEpochMillis() {
        XCTAssertEqual(AutoswitchRequest.fileName(at: now), "autoswitch-1789891428123.json")
        XCTAssertEqual(AutoswitchRequest.tempName(at: now), ".autoswitch-1789891428123.tmp")
    }

    func testWriteRenamesIntoPlaceAndLeavesNoTemp() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try AutoswitchRequest.write(enabled: true, at: now, into: dir)
        XCTAssertEqual(url.lastPathComponent, "autoswitch-1789891428123.json")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path),
                       ["autoswitch-1789891428123.json"])
        XCTAssertEqual(try Data(contentsOf: url), try AutoswitchRequest(enabled: true, at: now).encoded())
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testWriteRefusesAMissingDropDirectory() {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        XCTAssertThrowsError(try AutoswitchRequest.write(enabled: true, at: now, into: dir)) {
            XCTAssertEqual($0 as? AutoswitchRequest.WriteError, .noDropDirectory)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "must not create the directory")
    }

    // MARK: - Pending resolution

    private func resolve(snapshot: Bool, stale: Bool = false, _ pending: PendingToggle?,
                         after seconds: TimeInterval = 0) -> ToggleResolution {
        AutoswitchToggle.resolve(snapshotEnabled: snapshot, snapshotStale: stale,
                                 pending: pending, now: now.addingTimeInterval(seconds))
    }

    func testNoRequestShowsTheSnapshot() {
        XCTAssertEqual(resolve(snapshot: true, nil),
                       ToggleResolution(isOn: true, isPending: false, backendNotRunning: false))
    }

    func testDeliveredRequestShowsTheAskedForValueAsPending() {
        let pending = PendingToggle(desired: false, requestedAt: now, delivered: true)
        XCTAssertEqual(resolve(snapshot: true, pending, after: 5),
                       ToggleResolution(isOn: false, isPending: true, backendNotRunning: false))
    }

    func testSnapshotAgreeingSettlesIt() {
        let pending = PendingToggle(desired: false, requestedAt: now, delivered: true)
        XCTAssertEqual(resolve(snapshot: false, pending, after: 1),
                       ToggleResolution(isOn: false, isPending: false, backendNotRunning: false))
    }

    func testTimeoutReverts() {
        let pending = PendingToggle(desired: false, requestedAt: now, delivered: true)
        XCTAssertEqual(resolve(snapshot: true, stale: false, pending, after: 30),
                       ToggleResolution(isOn: true, isPending: false, backendNotRunning: false))
    }

    /// The dot and the words come from this one value, so a stale snapshot
    /// must not leave a pending request showing the asked-for state.
    func testStaleSnapshotDisablesTheControlAndShowsWhatWasPublished() {
        let pending = PendingToggle(desired: true, requestedAt: now, delivered: true)
        let inert = ToggleResolution(isOn: false, isPending: false, backendNotRunning: false, isDisabled: true)
        XCTAssertEqual(resolve(snapshot: false, stale: true, pending, after: 2), inert)
        XCTAssertEqual(resolve(snapshot: false, stale: true, pending, after: 45), inert)
        XCTAssertEqual(resolve(snapshot: false, stale: true, nil), inert)
        // The failed-write cue is the header's job once the snapshot is stale.
        let failed = PendingToggle(desired: true, requestedAt: now, delivered: false)
        XCTAssertEqual(resolve(snapshot: false, stale: true, failed, after: 2), inert)
    }

    func testFreshSnapshotLeavesTheControlLive() {
        XCTAssertFalse(resolve(snapshot: true, stale: false, nil).isDisabled)
        let pending = PendingToggle(desired: false, requestedAt: now, delivered: true)
        XCTAssertFalse(resolve(snapshot: true, stale: false, pending, after: 5).isDisabled)
    }

    func testFailedWriteNeverFlips() {
        let pending = PendingToggle(desired: false, requestedAt: now, delivered: false)
        XCTAssertEqual(resolve(snapshot: true, pending, after: 2),
                       ToggleResolution(isOn: true, isPending: false, backendNotRunning: true))
        XCTAssertEqual(resolve(snapshot: true, pending, after: 31),
                       ToggleResolution(isOn: true, isPending: false, backendNotRunning: false))
    }

    func testExpiryIsTheTimeoutWhileLive() {
        let pending = PendingToggle(desired: true, requestedAt: now, delivered: true)
        XCTAssertEqual(AutoswitchToggle.expiry(of: pending, now: now.addingTimeInterval(10)),
                       now.addingTimeInterval(AutoswitchToggle.pendingTimeout))
        XCTAssertNil(AutoswitchToggle.expiry(of: pending, now: now.addingTimeInterval(30)))
        XCTAssertNil(AutoswitchToggle.expiry(of: nil, now: now))
    }

    func testPendingRoundTripsThroughJSON() throws {
        let pending = PendingToggle(desired: true, requestedAt: now, delivered: false)
        XCTAssertEqual(try JSONDecoder().decode(PendingToggle.self, from: JSONEncoder().encode(pending)), pending)
    }
}
