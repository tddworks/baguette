import Testing
@testable import Baguette

@Suite("StreamConfig")
struct StreamConfigTests {

    @Test func `default is 60fps, 8Mbps, scale 1`() {
        let c = StreamConfig.default
        #expect(c.fps == 60)
        #expect(c.bitrateBps == 8_000_000)
        #expect(c.scale == 1)
    }

    @Test func `with-fps replaces only fps`() {
        let c = StreamConfig.default.with(fps: 30)
        #expect(c.fps == 30)
        #expect(c.bitrateBps == 8_000_000)
        #expect(c.scale == 1)
    }

    @Test func `with-bitrate replaces only bitrate`() {
        let c = StreamConfig.default.with(bitrateBps: 4_000_000)
        #expect(c.fps == 60)
        #expect(c.bitrateBps == 4_000_000)
        #expect(c.scale == 1)
    }

    @Test func `with-scale replaces only scale`() {
        let c = StreamConfig.default.with(scale: 2)
        #expect(c.fps == 60)
        #expect(c.bitrateBps == 8_000_000)
        #expect(c.scale == 2)
    }

    @Test func `with combines multiple replacements`() {
        let c = StreamConfig.default.with(fps: 30, bitrateBps: 1_000_000)
        #expect(c.fps == 30)
        #expect(c.bitrateBps == 1_000_000)
        #expect(c.scale == 1)
    }
}
