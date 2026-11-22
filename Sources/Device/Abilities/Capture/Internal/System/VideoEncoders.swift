import CoreMedia
import VideoToolbox

/// The video encoders VideoToolbox has on this Mac, by codec type.
enum VideoEncoders {
    static func installed() -> [CMVideoCodecType] {
        var list: CFArray?
        guard VTCopyVideoEncoderList(nil, &list) == noErr, let encoders = list as? [[String: Any]] else { return [] }
        return encoders.compactMap { ($0[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value }
    }
}
