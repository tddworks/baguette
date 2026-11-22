import Foundation

/// Which codec a browser receives, as the WHEP switch spells it
/// (`?codec=h265|h264|auto`): H.265 when its owner asked for it (`h265`, or
/// `auto`), the offer carries Main-profile H.265 and the owner can send it;
/// otherwise High-profile H.264, as before H.265 existed; neither, refused.
/// Asking for H.265 never refuses a browser that can take H.264, and with
/// nothing asked a browser gets H.264 only. Beside `CongestionChoice`, which
/// chooses the same way.
public enum CodecChoice: String, Sendable {
    case h265
    case h264
    case auto

    /// The codec to send, from what was asked, what the offer carries and what
    /// the owner's encoder can make; nil when nothing fits — the offer is refused.
    public static func codec(asked: CodecChoice?, offered: [VideoCodec], sendable: Set<VideoCodec.Kind>) -> VideoCodec? {
        let usable = offered.filter { $0.isSendableProfile && sendable.contains($0.kind) }
        let h264 = usable.first { $0.kind == .h264 }
        switch asked {
        case .h265?, .auto?: return usable.first { $0.kind == .h265 } ?? h264
        case .h264?, nil: return h264
        }
    }
}
