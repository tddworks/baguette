import Foundation

/// Which `ScreenReceiver` a phone's live screen uses. Both are run by the
/// same `PhoneScreen`; they differ in who turns the stream into pictures:
///
/// - `rtp` — baguette's own (`RTPReceiver`): our H.264
///   offer, the RTP depacketized and decoded here.
/// - `avconference` — Apple's (`AVConferenceReceiver`): AVConference's own
///   offer (HEVC), received, paced and decoded in-process by AVConference.
///
/// `BAGUETTE_PHONE_SCREEN=avconference` picks the second; anything else,
/// or nothing, is the first. Compared in docs/features/real-devices/screen-routes.md.
enum PhoneScreenRoute: String, Sendable {
    case rtp, avconference

    /// A receiver of this kind, for one session.
    func receiver() throws -> any ScreenReceiver {
        switch self {
        case .rtp: RTPReceiver()
        case .avconference: try AVConferenceReceiver()
        }
    }

    init(environment: [String: String]) {
        self = environment["BAGUETTE_PHONE_SCREEN"].flatMap(Self.init(rawValue:)) ?? .rtp
    }
}
