import Foundation
import IOSurface
import Mockable

/// The receiving end of a phone's screen mirroring, as AVConference plays
/// it in-process (Apple names the call `receiveMirroredPrimary`): it makes
/// the offer, takes the phone's answer, then receives the stream — the
/// phone's datagrams handed in, its reports for the phone handed out — and
/// decodes it. Single-use: one per session. Decides nothing — what goes
/// where, and which picture goes on, is `AVConferenceScreen`'s. The real
/// one is `AVConferenceMirroring`.
@Mockable
protocol Mirroring: AnyObject, Sendable {
    /// The negotiator's offer, sent to the phone as it is.
    func offer() throws -> Data
    /// The phone's answer to that offer.
    func accept(answer: Data) throws
    /// Start receiving, as the offer and answer agreed.
    func start() throws
    /// One datagram from the phone (RTP or RTCP).
    func deliver(_ datagram: Data)
    /// The next datagram for the phone (its RTCP), or nil when none came
    /// within a short wait.
    func nextReport() -> Data?
    /// The newest decoded picture, or nil before the first.
    func latestPicture() -> MirroredPicture?
    func stop()
}

/// A decoded picture of the phone's screen, BGRA, numbered in the order it
/// was decoded: the same number is the same picture.
struct MirroredPicture: @unchecked Sendable {
    let surface: IOSurface
    let sequence: Int
}
