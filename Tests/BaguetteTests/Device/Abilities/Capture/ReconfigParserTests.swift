import Testing
@testable import Baguette
@testable import BaguetteDevice

@Suite("ReconfigParser")
struct ReconfigParserTests {
    @Test func `should read a retune line as the one knob it turns`() {
        #expect(ReconfigParser.change(#"{"type":"set_bitrate","bps":4000000}"#) == .bitrate(4_000_000))
        #expect(ReconfigParser.change(#"{"type":"set_fps","fps":30}"#) == .fps(30))
        #expect(ReconfigParser.change(#"{"type":"set_scale","scale":2}"#) == .scale(2))
    }

    @Test func `should read no change from a line that isn't a well-formed retune`() {
        #expect(ReconfigParser.change("not json") == nil)
        #expect(ReconfigParser.change(#"{"type":"set_fps"}"#) == nil)
        #expect(ReconfigParser.change(#"{"type":"force_idr"}"#) == nil)
    }


    @Test func `should change only the bitrate on set_bitrate`() {
        let next = ReconfigParser.apply(
            #"{"type":"set_bitrate","bps":4000000}"#,
            to: .default
        )
        #expect(next == StreamConfig.default.with(bitrateBps: 4_000_000))
    }

    @Test func `should change only the fps on set_fps`() {
        let next = ReconfigParser.apply(
            #"{"type":"set_fps","fps":30}"#,
            to: .default
        )
        #expect(next == StreamConfig.default.with(fps: 30))
    }

    @Test func `should change only the scale on set_scale`() {
        let next = ReconfigParser.apply(
            #"{"type":"set_scale","scale":2}"#,
            to: .default
        )
        #expect(next == StreamConfig.default.with(scale: 2))
    }

    @Test func `should keep the stream config unchanged when the control is malformed JSON`() {
        let same = ReconfigParser.apply("not json", to: .default)
        #expect(same == .default)
    }

    @Test func `should keep the stream config unchanged when the control type is unknown`() {
        let same = ReconfigParser.apply(
            #"{"type":"frobnicate","x":1}"#,
            to: .default
        )
        #expect(same == .default)
    }

    @Test func `should keep the stream config unchanged when set_bitrate has no bps`() {
        let same = ReconfigParser.apply(#"{"type":"set_bitrate"}"#, to: .default)
        #expect(same == .default)
    }

    @Test func `should keep the stream config unchanged when set_fps has no fps`() {
        let same = ReconfigParser.apply(#"{"type":"set_fps"}"#, to: .default)
        #expect(same == .default)
    }

    @Test func `should keep the stream config unchanged when set_scale has no scale`() {
        let same = ReconfigParser.apply(#"{"type":"set_scale"}"#, to: .default)
        #expect(same == .default)
    }

    // Non-numeric payload: number() falls past the Double / Int branches
    // and returns nil — apply pins the config unchanged.
    @Test func `should keep the stream config unchanged when the bitrate is not a number`() {
        let same = ReconfigParser.apply(
            #"{"type":"set_bitrate","bps":"fast"}"#, to: .default
        )
        #expect(same == .default)
    }

    @Test func `should tell stream controls apart from gestures`() {
        for kind in ["set_bitrate", "set_fps", "set_scale", "force_idr", "snapshot"] {
            #expect(ReconfigParser.isStreamControl(#"{"type":"\#(kind)"}"#))
        }
        #expect(!ReconfigParser.isStreamControl(#"{"type":"down","x":1,"y":2}"#))
        #expect(!ReconfigParser.isStreamControl("not json"))
    }
}
