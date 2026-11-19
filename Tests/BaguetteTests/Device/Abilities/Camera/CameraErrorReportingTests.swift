import Foundation
import Testing

@testable import Baguette
@testable import BaguetteDevice

/// `CameraSession` reports a failed start to the browser as
/// `error.localizedDescription`, so every camera error that can reach
/// that path has to carry its own message there. An error that only
/// conforms to `CustomStringConvertible` gets Foundation's opaque
/// bridge instead ("The operation couldn't be completed. (Baguette.
/// StillImageError error 0.)"), which tells the user nothing.
@Suite("Camera error reporting")
struct CameraErrorReportingTests {

    @Test func `should report the exit status when an injection cleanup fails`() {
        let error: any Error = SimctlCapture.Failure.failed(udid: "U", status: 73, output: "")
        #expect(error.localizedDescription.contains("exited with status 73"))
    }

    @Test func `should name the file when a still image cannot be decoded`() {
        let error: any Error = StillImageError.decodeFailed("/tmp/pic.png")
        #expect(error.localizedDescription.contains("could not decode"))
        #expect(error.localizedDescription.contains("/tmp/pic.png"))
    }

    @Test func `should explain itself when a still image's drawing context cannot be made`() {
        let error: any Error = StillImageError.contextCreationFailed
        #expect(error.localizedDescription.contains("BGRA context"))
    }

    @Test func `should name the file when a video has no video track`() {
        let error: any Error = VideoDecoderError.noVideoTrack("/tmp/clip.mp4")
        #expect(error.localizedDescription.contains("no video track"))
        #expect(error.localizedDescription.contains("/tmp/clip.mp4"))
    }

    @Test func `should name the source kind when the producer cannot play it`() {
        let error: any Error = CameraCaptureError.unsupportedSource("video")
        #expect(error.localizedDescription.contains("video"))
    }

    /// The WS layer prints some errors with `String(describing:)`, so
    /// both spellings have to keep working.
    @Test func `should report the same message when an error is printed by description`() {
        #expect(String(describing: StillImageError.contextCreationFailed).contains("BGRA context"))
        #expect(String(describing: VideoDecoderError.notStarted).contains("not started"))
    }
}
