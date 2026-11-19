import BaguetteDevice
import Foundation
import IOSurface
import Mockable

/// Who turns a phone's screen stream into pictures — the one thing that
/// differs between ways of showing a phone's screen. It makes the offer the
/// phone is asked with, reads CoreDevice's answer, then takes the phone's
/// datagrams in, hands its reports for the phone out, and decodes, handing
/// each picture over the moment it is decoded. Single-use: one per session.
/// Decides nothing about the session — reaching the phone, where datagrams
/// go, when to give up for screenshots — which is `PhoneScreen`'s.
///
/// Two play it: `RTPReceiver` (baguette's own, H.264) and
/// `AVConferenceReceiver` (Apple's, in-process, HEVC); `PhoneScreenRoute`
/// picks one.
@Mockable
protocol ScreenReceiver: AnyObject, Sendable {
    /// The offer the phone is asked with, sent to it as it is.
    func offer() throws -> Data
    /// CoreDevice's answer (its `StartResponse`, as JSON); each receiver
    /// reads its own part of it.
    func accept(_ answer: [String: Any]) throws
    /// Start receiving, as the offer and answer agreed. Each picture,
    /// cropped to `screen` (in pixels) so the stream's padding is cut away,
    /// goes to `onPicture` as BGRA the moment it is decoded.
    func start(croppedTo screen: Size?, onPicture: @escaping @Sendable (IOSurface) -> Void) throws
    /// One datagram from the phone (RTP or RTCP).
    func receive(_ datagram: Data)
    /// The next datagram for the phone (its RTCP), or nil when none came
    /// within a short wait.
    func nextReport() -> Data?
    func stop()
}
