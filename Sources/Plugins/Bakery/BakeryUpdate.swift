import BaguetteDevice
import BaguetteDeviceFamilies
import Foundation

/// One trusted bakery, measured against what its remote holds now.
///
/// Notification, not application. Trust was granted to a specific
/// commit and that's what gets installed; this only reports that the
/// source has moved on since. Moving the pin forward stays a deliberate
/// act (`bakery update`) — an update that applied itself would let a
/// source you accepted once ship you anything later, which is the whole
/// reason the pin exists.
struct BakeryUpdate: Equatable, Sendable {
    let id: String
    /// The commit trust was granted to.
    let pinned: String
    /// What the remote's default branch points at now — `nil` when we
    /// couldn't ask.
    let head: String?

    enum State: Equatable, Sendable {
        case upToDate
        case available
        /// We couldn't reach the remote. Deliberately its own state:
        /// reporting "up to date" because the network was down tells
        /// the user the opposite of the truth.
        case unreachable
    }

    var state: State {
        guard let head else { return .unreachable }
        return head == pinned ? .upToDate : .available
    }

    /// One line for `bakery outdated`.
    var line: String {
        switch state {
        case .upToDate:
            return "\(id)  up to date  @\(Self.short(pinned))"
        case .available:
            return "\(id)  \(Self.short(pinned)) → \(Self.short(head ?? ""))  update available"
        case .unreachable:
            return "\(id)  @\(Self.short(pinned))  could not reach the remote"
        }
    }

    private static func short(_ commit: String) -> String {
        String(commit.prefix(7))
    }
}
