import Testing
import Foundation
@testable import Baguette

/// The sentences `baguette record` prints on its way out. They are
/// asserted because a recording fails minutes after the user walked
/// away — the message is the whole diagnosis, and a wrong one sends
/// them looking in the wrong place.
@Suite("RecordingError")
struct RecordingErrorTests {

    @Test func `should name the writable containers when the container is unwritable`() {
        #expect(RecordingError.unsupportedContainer("webm").message
            == "Unknown recording container 'webm'. Expected one of: mp4 | mov")
    }

    @Test func `should carry the reason when writing the recording fails`() {
        #expect(RecordingError.writerFailed("disk full").message
            == "Recording failed: disk full")
    }

    @Test func `should explain that no frame ever arrived when nothing was captured`() {
        #expect(RecordingError.noFramesCaptured.message
            == "No frames captured — the simulator screen never changed. "
                + "Drive some input while recording.")
    }
}
