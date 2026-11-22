import Foundation

/// A helper process's parent, as the helper started under it. The parent is
/// gone once the helper is handed to launchd (pid 1) — including when that
/// happened before the helper first looked, or it would wait forever.
public struct ParentProcess: Equatable, Sendable {
    public let startedUnder: Int32

    public init(startedUnder: Int32) {
        self.startedUnder = startedUnder
    }

    public func isGone(now: Int32) -> Bool {
        now != startedUnder || now == 1
    }
}
