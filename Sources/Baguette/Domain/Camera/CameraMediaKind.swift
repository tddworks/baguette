import BaguetteDevice
import Foundation

/// What kind of frame producer a host file feeds. Classifies by
/// extension only — pure and disk-free, so the upload route can reject
/// an unsupported drop before reading the body (mirroring how
/// `MediaItem.at` gates the Photos upload). `.image` decodes to a
/// single repeating frame; `.video` decodes to a looping stream.
enum CameraMediaKind: Equatable, Sendable {
    case image
    case video

    /// Still-image containers `CGImageSource` decodes.
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif"]
    /// Movie containers `AVAssetReader` reads a video track from.
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    /// Classify a host file, or `nil` when its extension is neither an
    /// image nor a video the camera can source from. Case-insensitive.
    static func at(_ url: URL) -> CameraMediaKind? {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        return nil
    }
}
