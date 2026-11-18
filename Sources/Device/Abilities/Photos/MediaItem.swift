import Foundation

/// A photo or video on the host destined for a device's camera roll —
/// the thing the user means when they drag an image or clip onto a
/// device and think "add this to Photos." `at(_:)` classifies by
/// extension (pure, no disk access, so the serve route can reject
/// before reading the upload body); `addMediaArguments` projects the
/// argv tail for `xcrun simctl addmedia <udid> <path>`. The
/// Infrastructure adapter (`SimctlPhotoLibrary`) just prepends `xcrun`
/// and runs it.
public struct MediaItem: Equatable, Sendable {
    public let path: URL

    public init(path: URL) {
        self.path = path
    }

    /// Extensions `xcrun simctl addmedia` lands in Photos — the image
    /// and video container formats the Simulator's Photos app imports.
    public static let mediaExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif",
        "mov", "mp4", "m4v",
    ]

    /// Classify a host file as importable media, or `nil` when its
    /// extension isn't an image/video Photos accepts. Extension-only,
    /// case-insensitive — pure and disk-free.
    public static func at(_ path: URL) -> MediaItem? {
        guard mediaExtensions.contains(path.pathExtension.lowercased()) else { return nil }
        return MediaItem(path: path)
    }

    /// The argv tail handed to `xcrun simctl [--set <set>] addmedia <udid> <path>`.
    public func addMediaArguments(udid: String, deviceSetPath: String? = nil) -> [String] {
        ["simctl"] + (deviceSetPath.map { ["--set", $0] } ?? []) + ["addmedia", udid, path.path]
    }
}
