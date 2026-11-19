import Foundation
import Mockable

/// The UDP socket a phone's live screen arrives on, and its RTCP goes back
/// through. Decides nothing — which datagrams are pictures and what to
/// answer is the `ScreenReceiver`'s, and where they go is `CoreDeviceScreen`'s. The real one is `UDPSocket`.
@Mockable
protocol DatagramSocket: AnyObject, Sendable {
    /// The port it receives on.
    var port: UInt16 { get }
    /// The next datagram, or nil when none came within its short wait
    /// (or it is closed).
    func receive() -> Data?
    func send(_ datagram: Data, to host: String, port: UInt16)
    func close()
}
