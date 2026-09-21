import Foundation

/// The `cswap snapshot` document (schema v1), as the widget reads it.
///
/// The producer is `src/claude_swap/snapshot_json.py`; the schema contract is
/// the committed golden fixture `tests/fixtures/snapshot_golden.json`, which
/// both the Python test and `SnapshotGoldenTests` assert against. A field
/// renamed, dropped or retyped on either side has to move on both.
struct Snapshot: Decodable, Sendable {
    let schemaVersion: Int
    let takenAt: Date
    let activeAccountNumber: Int?
    let accounts: [Account]
    /// Additive: absent from snapshots written before the backend published
    /// its auto-switch state. The widget then assumes the default threshold
    /// and shows no next-up or trend markers.
    let autoswitch: AutoSwitch?

    static func decode(_ data: Data) throws -> Snapshot {
        try decoder.decode(Snapshot.self, from: data)
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = SnapshotDate.parse(text) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath,
                          debugDescription: "not an ISO-8601 instant: \(text)")
                )
            }
            return date
        }
        return decoder
    }
}

/// The backend's auto-switch state, as of `takenAt`. Read-only in the widget.
struct AutoSwitch: Decodable, Sendable {
    let enabled: Bool
    /// Percent (0-100) at which the engine switches away from an account.
    let threshold: Double
    /// The account the engine would switch to next; null when there is none.
    let nextCandidateNumber: Int?
    /// Switches the engine made recently, oldest first. Optional so a producer
    /// that omits an empty list still decodes.
    let switches: [SwitchEvent]?
}

struct SwitchEvent: Decodable, Sendable {
    let date: Date
    let fromNumber: Int
    let toNumber: Int

    private enum CodingKeys: String, CodingKey {
        case date = "at", fromNumber = "from", toNumber = "to"
    }
}

/// One sample of a window's usage, for the 24h trend.
struct HistoryPoint: Decodable, Sendable, Equatable {
    let time: Date
    let pct: Double

    private enum CodingKeys: String, CodingKey {
        case time = "t", pct
    }
}

struct Account: Decodable, Sendable {
    let number: Int
    let email: String
    let organizationName: String
    /// Empty string for a personal account -- the producer never emits null here.
    let organizationUuid: String
    let isOrganization: Bool
    let active: Bool
    let kind: String
    let switchable: Bool
    /// `ok` when `usage` is populated; otherwise the machine-readable reason it
    /// is null (`api_key`, `token_expired`, `unavailable`, ...).
    let usageStatus: String
    let usage: Usage?
    /// Additive: absent unless the slot has one.
    let alias: String?
    /// Additive: emitted only as `true`, never as `false`.
    let disabled: Bool?
    /// Absent on a sentinel row, which has no measurement to be the age of.
    let usageFetchedAt: Date?
    let usageAgeSeconds: Double?

    var isDisabled: Bool { disabled ?? false }
    var label: String { alias ?? email }
}

struct Usage: Decodable, Sendable {
    let fiveHour: Window?
    let sevenDay: Window?
    let spend: Spend?
    /// Per-model weekly limits. Only these windows carry `name` and `maxed`.
    let scoped: [Window]?
}

/// A 5h, 7d or per-model usage window.
///
/// One struct for all three because the producer emits one shape; the fields a
/// given window kind never carries are optional. `name`/`maxed` appear on
/// `scoped` windows only, and the pace fields (`expectedPct`, `aheadOfPace`,
/// `projectedExhaustionAt`, `willLastToReset`) only on weekly windows, and
/// there only when pace is computable -- an absent `aheadOfPace` means "not
/// known", which is not the same as `false`.
struct Window: Decodable, Sendable {
    let pct: Double
    let resetsAt: Date?
    let expectedPct: Double?
    let aheadOfPace: Bool?
    let projectedExhaustionAt: Date?
    let willLastToReset: Bool?
    let name: String?
    let maxed: Bool?
    /// Additive, 5h window only: the last 24h of samples, oldest first (at
    /// most 288). Absent from snapshots that predate it.
    let history: [HistoryPoint]?

    // `countdown` and `clock` are deliberately NOT decoded. The producer
    // renders them at snapshot time from its own `datetime.now()` in the
    // producer's LOCAL timezone, so they are stale the moment the file is
    // written -- and the widget refreshes far more often than the snapshot is
    // regenerated. `resetsAt` is absolute; everything time-related is derived
    // from it instead.

    /// The menu bar's marker precedence: a maxed model outranks ahead-of-pace
    /// (see `usage_summary` in `src/claude_swap/menubar.py`).
    var marker: Marker {
        if maxed == true { return .maxed }
        if aheadOfPace == true { return .aheadOfPace }
        return .none
    }

    enum Marker: Sendable {
        case none
        case aheadOfPace
        case maxed
    }
}

struct Spend: Decodable, Sendable {
    let used: Double
    let limit: Double
    let pct: Double
    let currency: String
    let resetsAt: Date?
}

/// The document carries two ISO-8601 shapes and no single parser reads both.
///
/// `takenAt`, `usageFetchedAt` and `projectedExhaustionAt` are second-precision
/// UTC (`2026-09-20T10:03:48Z`). Every `resetsAt` is raw API passthrough with
/// six fractional digits and a numeric offset
/// (`2026-09-23T21:33:43.377897+00:00`).
///
/// `ISO8601DateFormatter` handles exactly one of them per option set: with
/// `.withFractionalSeconds` the plain `Z` form returns nil, and without it the
/// fractional form returns nil (verified on this toolchain). Two
/// `ISO8601FormatStyle`s tried in turn read both, and are not sensitive to how
/// lenient a given Foundation version happens to be.
enum SnapshotDate {
    static func parse(_ text: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }
}
