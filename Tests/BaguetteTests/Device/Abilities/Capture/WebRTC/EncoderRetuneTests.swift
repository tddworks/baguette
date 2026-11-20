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

    @Test func `should lower the encoder bitrate immediately when the available bandwidth drops sharply`() {
        var retune = EncoderRetune()
        #expect(retune.bitrate(for: 8_000_000, current: 6_000_000, now: 0) == 8_000_000)

        #expect(retune.bitrate(for: 1_700_000, current: 8_000_000, now: 100_000) == 1_700_000)
        #expect(retune.bitrate(for: 1_200_000, current: 1_700_000, now: 200_000) == 1_200_000)
    }

    @Test func `should wait before raising the encoder bitrate again`() {
        var retune = EncoderRetune()
        _ = retune.bitrate(for: 4_000_000, current: 8_000_000, now: 0)

        #expect(retune.bitrate(for: 6_000_000, current: 4_000_000, now: 999_999) == nil)
        #expect(retune.bitrate(for: 6_000_000, current: 4_000_000, now: 1_000_000) == 6_000_000)
    }
}
