import Testing
import Foundation
@testable import Baguette

@Suite("RecordingControl")
struct RecordingControlTests {

    @Test func `start_record decodes to .start`() {
        let cmd = RecordingControl.parse(#"{"type":"start_record"}"#)
        #expect(cmd == .start)
    }

    @Test func `stop_record decodes to .stop`() {
        let cmd = RecordingControl.parse(#"{"type":"stop_record"}"#)
        #expect(cmd == .stop)
    }

    @Test func `unknown type returns nil`() {
        #expect(RecordingControl.parse(#"{"type":"frobnicate"}"#) == nil)
    }

    @Test func `non-recording verb returns nil so reconfig keeps owning it`() {
        #expect(RecordingControl.parse(#"{"type":"set_fps","fps":30}"#) == nil)
        #expect(RecordingControl.parse(#"{"type":"force_idr"}"#) == nil)
    }

    @Test func `malformed JSON returns nil`() {
        #expect(RecordingControl.parse("not json") == nil)
        #expect(RecordingControl.parse("") == nil)
    }
}
