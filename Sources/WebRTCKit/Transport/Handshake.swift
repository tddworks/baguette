import Foundation
import Mockable

/// Where a DTLS handshake stands after a record from the browser.
public enum HandshakeProgress: Equatable, Sendable {
    /// Still going: send these records back.
    case continuing(replies: [Data])
    /// Done, and the browser presented the certificate its offer named: send
    /// these last records, then protect media with the 60 exported bytes.
    case complete(replies: [Data], srtpExport: [UInt8])
    /// The browser's certificate didn't match its offer, or DTLS gave up.
    case failed
}

/// A WebRTC viewer's DTLS-SRTP handshake (RFC 5764), as the DTLS server: the
/// browser connects (`a=setup:passive` in the answer). Its concrete form, in
/// `Internal/System/`, wraps BoringSSL and decides nothing the viewer should.
@Mockable
public protocol Handshake: AnyObject, Sendable {
    /// "sha-256 AB:CD:…" of the certificate this side presents, for the answer.
    var fingerprint: String { get }
    /// One record from the browser.
    func receive(_ record: Data) -> HandshakeProgress
    /// The records DTLS's retransmission timer says are due again.
    func resend() -> [Data]
}
