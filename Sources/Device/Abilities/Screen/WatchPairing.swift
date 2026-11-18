import Foundation
import Mockable

/// The Apple Watch simulator paired with a phone simulator. Its own
/// device in the set — its own udid, its own boot state, its own
/// framebuffer — so the browser streams it exactly like any other
/// device once it knows which one it is.
public struct PairedWatch: Sendable, Equatable {
    public let udid: String
    public let name: String
    /// The watch's state in the words every device shares.
    public let state: DeviceState

    public init(udid: String, name: String, state: DeviceState) {
        self.udid = udid
        self.name = name
        self.state = state
    }
}

/// One phone's side of the host's pairing table. Named for what it is
/// in the domain — a pairing — not for the `simctl` call behind it.
@Mockable
public protocol WatchPairing: Sendable {
    /// The watch paired with this phone, or nil when it has none.
    var watch: PairedWatch? { get }
}
