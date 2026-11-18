import Foundation
import Mockable

/// A device's photo library — "the camera roll on my phone." You add to
/// it by importing a `MediaItem` (image or video); listing / deleting
/// aren't modelled yet (drag-and-drop only ever *adds*).
///
/// `@Mockable` so the serve route and CLI command can be unit-tested
/// without a booted simulator. The production impl is
/// `SimctlPhotoLibrary`, backed by `xcrun simctl addmedia`.
@Mockable
public protocol PhotoLibrary: Sendable {
    /// Import a photo or video into the device's Photos. Throws
    /// `PhotoLibraryError.addFailed` when simctl exits non-zero.
    func add(_ media: MediaItem) async throws
}

/// Failure modes surfaced when adding media. Maps to a CLI exit message
/// and an HTTP 5xx on the serve route.
public enum PhotoLibraryError: Error, Equatable, CustomStringConvertible {
    case addFailed(status: Int32)

    public var description: String {
        switch self {
        case .addFailed(let status):
            return "xcrun simctl addmedia exited \(status)"
        }
    }
}
