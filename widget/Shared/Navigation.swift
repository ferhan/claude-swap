import Foundation

// Pure navigation logic for the list-based sizes, testable without WidgetKit.

/// What a master-detail size is showing. Stored per size in the extension's
/// own defaults (see `NavStore`), so two widgets of one size share it.
struct NavState: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable { case list, detail }

    var mode: Mode = .list
    var selectedAccountNumber: Int?
    /// Index into the size's list rows of the first row shown.
    var listOffset = 0
}

enum Navigation {
    /// List rows per window: the extra-large left column and the large list
    /// are both 344pt wide and draw the same three-line row (name, 5h, 7d),
    /// which leaves room for three.
    static let rowsPerPage = 3

    /// The sizes that keep a selection in `NavState`: medium shows one account
    /// at a time and its ‹ › move the selection, large drills into a detail
    /// view, extra-large shows the selection in its right column. Small is the
    /// one size still driven by `PageStore`.
    static func usesSelection(_ family: LayoutFamily) -> Bool { family != .small }

    /// The sizes that draw the account list. Medium keeps a selection too, but
    /// has room for one account, not a list of them.
    static func showsAccountList(_ family: LayoutFamily) -> Bool {
        family == .large || family == .extraLarge
    }

    /// The list rows, split into the windows ▲/▼ move between. Widgets cannot
    /// scroll, so overflow is paged a window at a time.
    static func listChunks(for family: LayoutFamily, snapshot: Snapshot) -> [[Account]] {
        guard showsAccountList(family) else { return [snapshot.orderedAccounts] }
        let accounts = snapshot.orderedAccounts
        guard !accounts.isEmpty else { return [[]] }
        return stride(from: 0, to: accounts.count, by: rowsPerPage).map {
            Array(accounts[$0..<min($0 + rowsPerPage, accounts.count)])
        }
    }

    /// The chunk that holds row `offset`; past the end, the last chunk.
    static func chunkIndex(offset: Int, chunks: [[Account]]) -> Int {
        var start = 0
        for (index, chunk) in chunks.enumerated() {
            start += chunk.count
            if offset < start { return index }
        }
        return max(chunks.count - 1, 0)
    }

    static func chunkStart(_ index: Int, chunks: [[Account]]) -> Int {
        chunks.prefix(index).reduce(0) { $0 + $1.count }
    }

    /// Tapping a row selects it in place, on both sizes. Opening the detail
    /// is a second tap, on the selected row's "Details ›" -- large only, since
    /// extra-large's right column already shows the selection.
    static func select(_ number: Int, in state: NavState) -> NavState {
        var next = state
        next.selectedAccountNumber = number
        next.mode = .list
        return next
    }

    /// Where medium's ‹ › move the selection: the next or previous account in
    /// display order, wrapping at the ends. Nil when there is no account to
    /// move to.
    static func neighbor(of number: Int, in accounts: [Account], by delta: Int) -> Int? {
        guard !accounts.isEmpty else { return nil }
        let current = accounts.firstIndex { $0.number == number } ?? 0
        let count = accounts.count
        return accounts[(((current + delta) % count) + count) % count].number
    }

    /// "Details ›": drill into the row that is already selected.
    static func openDetail(_ number: Int, in state: NavState) -> NavState {
        var next = state
        next.selectedAccountNumber = number
        next.mode = .detail
        return next
    }

    /// "‹ Back": the list again, with the account still selected.
    static func back(_ state: NavState) -> NavState {
        var next = state
        next.mode = .list
        return next
    }

    /// ▲/▼: move by `delta` windows, clamped to the first and last.
    static func scroll(_ state: NavState, by delta: Int, chunks: [[Account]]) -> NavState {
        let current = chunkIndex(offset: state.listOffset, chunks: chunks)
        let target = min(max(current + delta, 0), max(chunks.count - 1, 0))
        var next = state
        next.listOffset = chunkStart(target, chunks: chunks)
        return next
    }

    /// The stored state made valid for this snapshot: an account that has gone
    /// takes the detail back to the list, the selection falls back to the
    /// active account, and an offset past the rows snaps to the last window's
    /// start. Large is the only size with a detail mode -- medium and
    /// extra-large show the selection in place.
    static func resolve(_ state: NavState, snapshot: Snapshot, family: LayoutFamily) -> NavState {
        var next = state
        if let number = next.selectedAccountNumber, snapshot.account(number: number) == nil {
            next.selectedAccountNumber = nil
            next.mode = .list
        }
        if family != .large { next.mode = .list }
        if next.selectedAccountNumber == nil {
            next.selectedAccountNumber = (snapshot.activeAccount ?? snapshot.orderedAccounts.first)?.number
        }
        // No accounts at all: there is nothing to drill into.
        if next.selectedAccountNumber == nil { next.mode = .list }
        let chunks = listChunks(for: family, snapshot: snapshot)
        next.listOffset = chunkStart(chunkIndex(offset: max(next.listOffset, 0), chunks: chunks), chunks: chunks)
        return next
    }
}
