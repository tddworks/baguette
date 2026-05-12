import AVFoundation
import CoreVideo
import Foundation
import IOSurface

/// Production `VideoDecoder` — decodes a video file using
/// `AVAssetReader` and delivers each frame as an `IOSurface` to the
/// caller's `onFrame` closure.
///
/// Loops the video continuously until the owning `Task` is cancelled.
/// Errors in track loading, reader initialisation, or frame delivery
/// are propagated (not swallowed), so callers always know about
/// decode failures.
final class AVFoundationVideoDecoder: VideoDecoder, @unchecked Sendable {

    /// Decode and loop a video file, calling `onFrame` for each
    /// decoded frame at the video's native frame rate.
    ///
    /// - Parameters:
    ///   - url: Local file URL of the video (`.mp4`, `.mov`, etc.).
    ///   - onFrame: Called with each decoded `IOSurface`. The closure
    ///     may throw to signal a delivery failure (e.g. the camera
    ///     descriptor rejected the frame).
    /// - Throws: `CameraError.videoDecodingFailed` if the asset has
    ///   no video track or the reader can't start. Re-throws any
    ///   error from `onFrame`. Throws `CancellationError` on normal
    ///   cancellation.
    func decodeLoop(
        url: URL,
        onFrame: @escaping @Sendable (IOSurface) throws -> Void
    ) async throws {
        let asset = AVURLAsset(url: url)

        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              let track = tracks.first
        else {
            throw CameraError.videoDecodingFailed
        }

        let nominalFPS = (try? await track.load(.nominalFrameRate)) ?? 30.0
        let frameInterval: UInt64 = nominalFPS > 0
            ? UInt64(1_000_000_000.0 / Double(nominalFPS))
            : 33_333_333

        while !Task.isCancelled {
            try Task.checkCancellation()

            guard let reader = try? AVAssetReader(asset: asset) else {
                throw CameraError.videoDecodingFailed
            }
            let outputSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]
            let output = AVAssetReaderTrackOutput(
                track: track, outputSettings: outputSettings
            )
            reader.add(output)

            guard reader.startReading() else {
                throw CameraError.videoDecodingFailed
            }

            while !Task.isCancelled, reader.status == .reading {
                guard let sampleBuffer = output.copyNextSampleBuffer(),
                      let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
                else { continue }

                CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }

                if let surfaceRef = CVPixelBufferGetIOSurface(imageBuffer) {
                    let surface = unsafeBitCast(surfaceRef, to: IOSurface.self)
                    try onFrame(surface)
                }

                try await Task.sleep(nanoseconds: frameInterval)
            }

            reader.cancelReading()
        }

        throw CancellationError()
    }
}
