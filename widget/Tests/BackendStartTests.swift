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

    // MARK: - Finding cswap

    private func snapshot(_ command: [String]?) -> Data {
        var object: [String: Any] = ["schemaVersion": 1]
        if let command { object["cswapCommand"] = command }
        return try! JSONSerialization.data(withJSONObject: object) // swiftlint:disable:this force_try
    }

    func testSnapshotCommandWins() {
        let command = ["/Users/u/.local/pipx/venvs/claude-swap/bin/python", "-m", "claude_swap"]
        XCTAssertEqual(BackendStart.cswapCommand(snapshot: snapshot(command), home: "/Users/u",
                                                 isExecutable: { _ in true }), command)
    }

    func testFallsBackInOrderWhenTheSnapshotNamesNone() {
        let installed: Set = ["/opt/homebrew/bin/cswap", "/usr/local/bin/cswap"]
        XCTAssertEqual(BackendStart.cswapCommand(snapshot: snapshot(nil), home: "/Users/u",
                                                 isExecutable: installed.contains), ["/opt/homebrew/bin/cswap"])
        XCTAssertEqual(BackendStart.cswapCommand(snapshot: nil, home: "/Users/u",
                                                 isExecutable: { $0 == "/Users/u/.local/bin/cswap" }),
                       ["/Users/u/.local/bin/cswap"])
    }

    func testIgnoresACommandThatIsNotAnAbsoluteExecutable() {
        let installed: Set = ["/usr/local/bin/cswap"]
        XCTAssertEqual(BackendStart.cswapCommand(snapshot: snapshot(["cswap"]), home: "/Users/u",
                                                 isExecutable: { _ in true }), ["/Users/u/.local/bin/cswap"])
        XCTAssertEqual(BackendStart.cswapCommand(snapshot: snapshot(["/gone/cswap"]), home: "/Users/u",
                                                 isExecutable: installed.contains), ["/usr/local/bin/cswap"])
        XCTAssertNil(BackendStart.cswapCommand(snapshot: snapshot([]), home: "/Users/u", isExecutable: { _ in false }))
    }
}
