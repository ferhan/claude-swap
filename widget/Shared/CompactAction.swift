import Foundation

// The one action spot small and medium have: which of the three controls it
// carries. Pure Foundation, so the test target exercises the choice directly.

/// What the compact action spot draws. Small's is its bottom line, beside the
/// pager; medium's is its right column's bottom line, beside the ‹ ›.
enum CompactAction: Equatable, Sendable {
    /// The backend is not republishing: nothing else in the spot would be
    /// applied, so it offers the start instead.
    case start
    /// The auto-switch toggle. The green dot beside the name already says
    /// which account is in use, so the spot carries something to press rather
    /// than the word "Active".
    case auto
    /// Any other account: the switch control, with all its states.
    case switchAccount
}

enum CompactSlot {
    /// - Parameters:
    ///   - family: `.small` or `.medium` -- the two sizes with one such spot.
    ///     They differ in one way: medium's left column carries the start
    ///     control, so a stopped backend leaves this spot to the auto chip,
    ///     drawn inert, rather than a second start.
    ///   - hasAutoswitch: the snapshot carries an `autoswitch` block. Without
    ///     one there is no toggle to draw: the active account keeps the
    ///     "Active" marker the switch control shows for it, and medium with a
    ///     stopped backend leaves the spot empty -- its left column is already
    ///     offering the only thing that would help.
    static func resolve(family: LayoutFamily, eligibility: SwitchEligibility,
                        backendStale: Bool, hasAutoswitch: Bool) -> CompactAction {
        if backendStale { return family == .medium ? .auto : .start }
        if eligibility == .active { return hasAutoswitch ? .auto : .switchAccount }
        return .switchAccount
    }
}
