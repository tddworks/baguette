import BaguetteDevice
import Foundation

/// The container a recording lands in. There is no `--format` flag: the
/// user already said which one they wanted when they named the output
/// file, and two ways of saying the same thing is one way too many.
///
/// Both containers carry H.264 video — the codec isn't the variable
/// here, the wrapper is. `AVAssetWriterReel` maps these onto
/// `AVFileType`; the domain never imports AVFoundation.
enum RecordingFormat: String, Equatable, Sendable, CaseIterable {
    case mp4
    case mov

    /// One line naming every container — for `--help` and error messages.
    static var containerList: String {
        allCases.map(\.rawValue).joined(separator: " | ")
    }

    /// Derive the container from the file the user named. Unknown (or
    /// absent) extensions throw — baguette never silently records a
    /// `.webm` request into an MP4.
    static func forFile(_ url: URL) throws -> RecordingFormat {
        let ext = url.pathExtension.lowercased()
        guard let format = RecordingFormat(rawValue: ext) else {
            throw RecordingError.unsupportedContainer(ext)
        }
        return format
    }
}
