import Foundation

// Pure navigation logic for the list-based sizes, testable without WidgetKit.

/// What a list-based size is showing. Stored per size in the extension's own
/// defaults (see `NavStore`), so two widgets of one size share it.
struct NavState: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable { case list, detail }

    var mode: Mode = .list
    var selectedAccountNumber: Int?
    /// Index into the size's list rows of the first row shown.
    var listOffset = 0
}

enum Navigation {
    /// Extra-large list rows per window of the left column. Three lines per
    /// row (name, 5h, 7d) leave room for three rows.
    static let extraLargeRowsPerPage = 3

    /// The list rows, split into the windows ▲/▼ move between. Widgets cannot
    /// scroll, so overflow is paged a window at a time.
    static func listChunks(for family: LayoutFamily, snapshot: Snapshot) -> [[Account]] {
        switch family {
        case .extraLarge:
            let accounts = snapshot.orderedAccounts
            guard !accounts.isEmpty else { return [[]] }
            return stride(from: 0, to: accounts.count, by: extraLargeRowsPerPage).map {
                Array(accounts[$0..<min($0 + extraLargeRowsPerPage, accounts.count)])
            }
        case .small, .medium, .large:
            return Paging.overviewChunks(for: family, snapshot: snapshot)
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

    /// Tapping a row: extra-large selects in place, the others drill down.
    static func select(_ number: Int, in state: NavState, family: LayoutFamily) -> NavState {
        var next = state
        next.selectedAccountNumber = number
        next.mode = family == .extraLarge ? .list : .detail
        return next
    }

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

    /// The stored state made valid for this snapshot: a selected account that
    /// has gone falls back to the list (extra-large: to the active account),
    /// and an offset past the rows snaps to the last window's start.
    static func resolve(_ state: NavState, snapshot: Snapshot, family: LayoutFamily) -> NavState {
        var next = state
        if let number = next.selectedAccountNumber, snapshot.account(number: number) == nil {
            next.selectedAccountNumber = nil
        }
        if family == .extraLarge {
            next.mode = .list
            if next.selectedAccountNumber == nil {
                next.selectedAccountNumber = (snapshot.activeAccount ?? snapshot.orderedAccounts.first)?.number
            }
        } else if next.selectedAccountNumber == nil {
            next.mode = .list
        }
        let chunks = listChunks(for: family, snapshot: snapshot)
        next.listOffset = chunkStart(chunkIndex(offset: max(next.listOffset, 0), chunks: chunks), chunks: chunks)
        return next
    }
}
