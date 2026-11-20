import Foundation
import Mockable

/// A WebRTC viewer's UDP socket: the one port its browser's STUN, DTLS, SRTP
/// and SRTCP all share (RFC 7983). Its concrete form, in `Internal/System/`,
/// only moves bytes; the viewer decides what they are.
@Mockable
public protocol Datagrams: AnyObject, Sendable {
    /// Where a browser can reach this socket: its host candidates.
    var addresses: [DatagramAddress] { get }
    func send(_ datagram: Data, to address: DatagramAddress)
    /// Every datagram that arrives, with where it came from.
    func onReceive(_ handler: @escaping @Sendable (Data, DatagramAddress) -> Void)
    func close()
}
