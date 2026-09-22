import Foundation

// "Switch to this account", minus the drawing: who may be switched to, the
// request file the widget drops, and how a pending switch resolves against
// the snapshot. Pure Foundation, so the test target exercises it directly.

/// A request to switch the active account, dropped into
/// `~/.claude-swap-backup/widget-requests/`. The backend applies a fresh one
/// (under 60s old) through the same path as `cswap switch N` and republishes
/// the snapshot with the new `activeAccountNumber`.
///
/// Contract: `switch-<epochMillis>.json`, written as `.switch-<epochMillis>.tmp`
/// then renamed, mode 0600. Content: `{"switch": {"to": 3}, "at": "<ISO8601>"}`.
struct SwitchRequest: Encodable, Equatable, Sendable {
    let target: SwitchTarget
    let requestedAt: String

    private enum CodingKeys: String, CodingKey {
        case target = "switch", requestedAt = "at"
    }

    init(to number: Int, at date: Date) {
        target = SwitchTarget(number: number)
        requestedAt = date.formatted(Date.ISO8601FormatStyle())
    }

    static func fileName(at date: Date) -> String { "switch-\(RequestDrop.millis(date)).json" }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }

    @discardableResult
    static func write(to number: Int, at date: Date, into directory: URL) throws -> URL {
        try RequestDrop.write(SwitchRequest(to: number, at: date).encoded(),
                              name: fileName(at: date), into: directory)
    }
}

/// The `{"to": 3}` inside a switch request.
struct SwitchTarget: Encodable, Equatable, Sendable {
    let number: Int
    private enum CodingKeys: String, CodingKey { case number = "to" }
}

/// Whether the detail view offers "Switch to this account".
enum SwitchEligibility: Equatable, Sendable {
    case eligible
    /// Already the active account: nothing to switch to.
    case active
    /// No stored credentials/config backup: `cswap switch` would refuse it.
    case notSwitchable
}

extension Account {
    /// The same rule `cswap switch N` applies (`switch_to` in
    /// `src/claude_swap/switcher.py`): the slot must hold a usable backup
    /// (`switchable`). A disabled slot is only held out of *automatic*
    /// rotation and stays a valid explicit target, and `kind` is not checked
    /// -- an API-key slot with a backup switches like any other.
    func switchEligibility(activeNumber: Int?) -> SwitchEligibility {
        if active || number == activeNumber { return .active }
        return switchable ? .eligible : .notSwitchable
    }
}

/// What the widget remembers after a switch tap, in its own defaults, until
/// the snapshot shows the target active.
struct PendingSwitch: Codable, Equatable, Sendable {
    var target: Int
    var requestedAt: Date
    /// False when no request was written (stale snapshot, no drop directory,
    /// write error): nothing was asked of the backend.
    var delivered: Bool
}

enum SwitchState: Equatable, Sendable {
    case idle
    /// A request for this account is out and the snapshot has not caught up.
    case switching(target: Int)
    /// The request timed out or was never delivered.
    case notApplied(target: Int)
}

enum AccountSwitch {
    /// How long a request may stay unconfirmed before the widget gives up.
    static let pendingTimeout: TimeInterval = 30
    /// How long "Switch not applied" stays up after that.
    static let failureShownFor: TimeInterval = 30

    static func resolve(activeNumber: Int?, pending: PendingSwitch?, now: Date) -> SwitchState {
        guard let pending, activeNumber != pending.target else { return .idle }
        let age = now.timeIntervalSince(pending.requestedAt)
        guard pending.delivered else {
            return age < failureShownFor ? .notApplied(target: pending.target) : .idle
        }
        if age < pendingTimeout { return .switching(target: pending.target) }
        if age < pendingTimeout + failureShownFor { return .notApplied(target: pending.target) }
        return .idle
    }

    /// When the drawn state next changes without a new snapshot. Nil when
    /// nothing is waiting.
    static func expiry(of pending: PendingSwitch?, now: Date) -> Date? {
        guard let pending else { return nil }
        let marks = pending.delivered
            ? [pendingTimeout, pendingTimeout + failureShownFor]
            : [failureShownFor]
        return marks.map { pending.requestedAt.addingTimeInterval($0) }.first { $0 > now }
    }
}
