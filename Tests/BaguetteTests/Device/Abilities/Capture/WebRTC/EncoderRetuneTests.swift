import Foundation
import Testing
@testable import BaguetteDevice

@Suite("EncoderRetune")
struct EncoderRetuneTests {
    @Test func `should retune the encoder to a target that moved by more than 10 percent`() {
        var retune = EncoderRetune()

        #expect(retune.bitrate(for: 4_000_000, current: 8_000_000, now: 0) == 4_000_000)
        #expect(retune.bitrate(for: 8_000_000, current: 4_000_000, now: 2_000_000) == 8_000_000)
    }

    @Test func `should leave the encoder alone when the target moved by 10 percent or less`() {
        var retune = EncoderRetune()

        #expect(retune.bitrate(for: 7_200_000, current: 8_000_000, now: 0) == nil)
        #expect(retune.bitrate(for: 8_800_000, current: 8_000_000, now: 0) == nil)
    }

    @Test func `should retune at most once a second`() {
        var retune = EncoderRetune()
        _ = retune.bitrate(for: 4_000_000, current: 8_000_000, now: 0)

        #expect(retune.bitrate(for: 2_000_000, current: 4_000_000, now: 999_999) == nil)
        #expect(retune.bitrate(for: 2_000_000, current: 4_000_000, now: 1_000_000) == 2_000_000)
    }
}
