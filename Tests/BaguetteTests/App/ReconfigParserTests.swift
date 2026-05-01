import Testing
@testable import Baguette

@Suite("ReconfigParser")
struct ReconfigParserTests {

    @Test func `set-bitrate updates only bitrate`() {
        let next = ReconfigParser.apply(
            #"{"type":"set_bitrate","bps":4000000}"#,
            to: .default
        )
        #expect(next == StreamConfig.default.with(bitrateBps: 4_000_000))
    }

    @Test func `set-fps updates only fps`() {
        let next = ReconfigParser.apply(
            #"{"type":"set_fps","fps":30}"#,
            to: .default
        )
        #expect(next == StreamConfig.default.with(fps: 30))
    }

    @Test func `set-scale updates only scale`() {
        let next = ReconfigParser.apply(
            #"{"type":"set_scale","scale":2}"#,
            to: .default
        )
        #expect(next == StreamConfig.default.with(scale: 2))
    }

    @Test func `malformed JSON returns the input config unchanged`() {
        let same = ReconfigParser.apply("not json", to: .default)
        #expect(same == .default)
    }

    @Test func `unknown type returns the input config unchanged`() {
        let same = ReconfigParser.apply(
            #"{"type":"frobnicate","x":1}"#,
            to: .default
        )
        #expect(same == .default)
    }

    @Test func `missing payload field returns the input config unchanged`() {
        let same = ReconfigParser.apply(#"{"type":"set_bitrate"}"#, to: .default)
        #expect(same == .default)
    }

    @Test func `missing fps field returns the input config unchanged`() {
        let same = ReconfigParser.apply(#"{"type":"set_fps"}"#, to: .default)
        #expect(same == .default)
    }

    @Test func `missing scale field returns the input config unchanged`() {
        let same = ReconfigParser.apply(#"{"type":"set_scale"}"#, to: .default)
        #expect(same == .default)
    }

    // Non-numeric payload: number() falls past the Double / Int branches
    // and returns nil — apply pins the config unchanged.
    @Test func `non-numeric bitrate payload returns the input config unchanged`() {
        let same = ReconfigParser.apply(
            #"{"type":"set_bitrate","bps":"fast"}"#, to: .default
        )
        #expect(same == .default)
    }
}
