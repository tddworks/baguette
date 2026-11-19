import Foundation

/// What a pose change — a fold or a rotation — established.
public enum PoseDelivery: Equatable, Sendable {
    case delivered
    case rejected
    /// The guest helper stopped answering and was stopped: the change may
    /// have been delivered before its deadline, but will not be delivered later.
    case unconfirmed

    /// The outcome of a pose change that failed with `error`.
    public init(failure error: any Error) {
        self = (error as? HingeError) == .toolTimedOut ? .unconfirmed : .rejected
    }
}
