import Testing
@testable import Baguette
@testable import BaguetteDevice

@Suite("StreamConfig")
struct StreamConfigTests {

    @Test func `should stream at 60fps, 8Mbps and scale 1 by default`() {
        let c = StreamConfig.default
        #expect(c.fps == 60)
        #expect(c.bitrateBps == 8_000_000)
        #expect(c.scale == 1)
    }

    @Test func `should change only the frame rate when a new fps is set`() {
        let c = StreamConfig.default.with(fps: 30)
        #expect(c.fps == 30)
        #expect(c.bitrateBps == 8_000_000)
        #expect(c.scale == 1)
    }

    @Test func `should change only the bitrate when a new bitrate is set`() {
        let c = StreamConfig.default.with(bitrateBps: 4_000_000)
        #expect(c.fps == 60)
        #expect(c.bitrateBps == 4_000_000)
        #expect(c.scale == 1)
    }

    @Test func `should change only the scale when a new scale is set`() {
        let c = StreamConfig.default.with(scale: 2)
        #expect(c.fps == 60)
        #expect(c.bitrateBps == 8_000_000)
        #expect(c.scale == 2)
    }

    @Test func `should change several settings at once while keeping the rest`() {
        let c = StreamConfig.default.with(fps: 30, bitrateBps: 1_000_000)
        #expect(c.fps == 30)
        #expect(c.bitrateBps == 1_000_000)
        #expect(c.scale == 1)
    }

    @Test func `should change only the setting a change names`() {
        let config = StreamConfig(fps: 30, bitrateBps: 2_000_000, scale: 1)

        #expect(StreamConfig.Change.bitrate(4_000_000).applied(to: config) == config.with(bitrateBps: 4_000_000))
        #expect(StreamConfig.Change.fps(60).applied(to: config) == config.with(fps: 60))
        #expect(StreamConfig.Change.scale(2).applied(to: config) == config.with(scale: 2))
    }

    @Test func `should start an MJPEG stream at half size and 30 frames a second`() {
        let c = StreamConfig.default(for: .mjpeg)
        #expect(c.scale == 2)
        #expect(c.fps == 30)
    }

    @Test func `should start an AVCC stream at the full default`() {
        #expect(StreamConfig.default(for: .avcc) == .default)
    }
}
