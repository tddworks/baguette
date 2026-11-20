import Foundation
import Mockable

/// What a `WebRTCSender` tells whoever feeds it frames: the sender decides how
/// the frames travel; its owner decides what the encoder makes. Called outside
/// the sender's lock, so an owner may call back into it.
@Mockable
public protocol SenderEvents: AnyObject, Sendable {
    /// The browser can't show a picture until the next keyframe: when its
    /// session is first secured, and when it reports a lost picture.
    func keyframeNeeded()
    /// What the link can take, after the browser's feedback — the owner decides
    /// whether and when its encoder follows. `at` is microseconds on the
    /// sender's clock.
    func estimated(bitrate: Int, at now: Int64)
    /// The session is over — asked for, a failed handshake, or the browser
    /// gone quiet. Called once; the sender never sends again.
    func hungUp()
    /// One line of what happened, with the session's id and a wall-clock time.
    func diagnostic(_ line: String)
}
