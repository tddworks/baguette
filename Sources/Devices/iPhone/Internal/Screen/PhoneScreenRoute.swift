import Foundation

/// Which way a phone's live screen reaches the Mac. Both start the phone's
/// own stream through CoreDevice; they differ in who receives it:
///
/// - `avconference` — Apple's (`AVConferenceScreen`): AVConference's own
///   offer (HEVC), received, paced and decoded in-process by AVConference.
/// - `rtp` — baguette's own receiver (`MediaStreamScreen`): our H.264
///   offer, the RTP depacketized and decoded here.
///
/// `BAGUETTE_PHONE_SCREEN=rtp` picks the second; anything else, or
/// nothing, is the first. Compared in docs/features/real-devices/screen-routes.md.
enum PhoneScreenRoute: String, Sendable {
    case rtp, avconference

    init(environment: [String: String]) {
        self = environment["BAGUETTE_PHONE_SCREEN"].flatMap(Self.init(rawValue:)) ?? .avconference
    }
}
