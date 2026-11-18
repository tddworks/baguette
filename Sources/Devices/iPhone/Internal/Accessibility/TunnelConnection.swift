import Foundation
import Mockable

/// A connection to one of the phone's services over its CoreDevice tunnel:
/// bytes written, and exactly so many read back before a deadline. Decides
/// nothing — the conversation is its caller's, in the pure wire values
/// (`HTTP2Frame`, `XPCMessage`, `DTXMessage`). The real one is `TunnelSocket`.
@Mockable
protocol TunnelConnection: AnyObject {
    func write(_ data: Data) throws
    /// Exactly `count` bytes, or a failure once `deadline` passes.
    func read(_ count: Int, by deadline: Date) throws -> Data
}

extension TunnelSocket: TunnelConnection {}
