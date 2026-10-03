import Foundation
import Testing

@testable import Baguette

/// `CameraSession` reports a failed start to the browser as
/// `error.localizedDescription`, so every camera error that can reach
/// that path has to carry its own message there. An error that only
/// conforms to `CustomStringConvertible` gets Foundation's opaque
/// bridge instead ("The operation couldn't be completed. (Baguette.
/// StillImageError error 0.)"), which tells the user nothing.
@Suite("Camera error reporting")
struct CameraErrorReportingTests {

    @Test func `an injection cleanup failure preserves the native exit status`() {
        let error: any Error = SimctlCapture.Failure.failed(udid: "U", status: 73, output: "")
        #expect(error.localizedDescription.contains("exited with status 73"))
    }

    @Test func `a still-image decode failure names the file it couldn't read`() {
        let error: any Error = StillImageError.decodeFailed("/tmp/pic.png")
        #expect(error.localizedDescription.contains("could not decode"))
        #expect(error.localizedDescription.contains("/tmp/pic.png"))
    }

    @Test func `a still-image context failure explains itself`() {
        let error: any Error = StillImageError.contextCreationFailed
        #expect(error.localizedDescription.contains("BGRA context"))
    }

    @Test func `a video decode failure names the file it couldn't read`() {
        let error: any Error = VideoDecoderError.noVideoTrack("/tmp/clip.mp4")
        #expect(error.localizedDescription.contains("no video track"))
        #expect(error.localizedDescription.contains("/tmp/clip.mp4"))
    }

    @Test func `an unsupported source names the kind the producer was handed`() {
        let error: any Error = CameraCaptureError.unsupportedSource("video")
        #expect(error.localizedDescription.contains("video"))
    }

    /// The WS layer prints some errors with `String(describing:)`, so
    /// both spellings have to keep working.
    @Test func `the description spelling keeps reporting the same message`() {
        #expect(String(describing: StillImageError.contextCreationFailed).contains("BGRA context"))
        #expect(String(describing: VideoDecoderError.notStarted).contains("not started"))
    }
}
