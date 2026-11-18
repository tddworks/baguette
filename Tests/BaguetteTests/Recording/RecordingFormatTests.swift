import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// The container a recording is written into is decided by the file the
/// user names — `demo.mp4` is an MP4, `demo.mov` a QuickTime movie.
@Suite("RecordingFormat")
struct RecordingFormatTests {

    @Test func `should record into an MP4 container when the filename ends in mp4`() throws {
        let format = try RecordingFormat.forFile(URL(fileURLWithPath: "/tmp/demo.mp4"))
        #expect(format == .mp4)
    }

    @Test func `should record into a QuickTime container when the filename ends in mov`() throws {
        let format = try RecordingFormat.forFile(URL(fileURLWithPath: "/tmp/demo.MOV"))
        #expect(format == .mov)
    }

    @Test func `should reject an unknown extension rather than guess at it`() {
        #expect(throws: RecordingError.unsupportedContainer("webm")) {
            _ = try RecordingFormat.forFile(URL(fileURLWithPath: "/tmp/demo.webm"))
        }
    }

    @Test func `should reject a filename with no extension`() {
        #expect(throws: RecordingError.unsupportedContainer("")) {
            _ = try RecordingFormat.forFile(URL(fileURLWithPath: "/tmp/demo"))
        }
    }

    @Test func `should name every writable container when rejecting one`() {
        #expect(RecordingError.unsupportedContainer("webm").message
            == "Unknown recording container 'webm'. Expected one of: mp4 | mov")
    }

    @Test func `should list the containers users can pick from`() {
        #expect(RecordingFormat.containerList == "mp4 | mov")
    }
}
