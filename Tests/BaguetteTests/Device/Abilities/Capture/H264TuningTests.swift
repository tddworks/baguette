import Testing
@testable import Baguette
@testable import BaguetteDevice

@Suite("H264Tuning")
struct H264TuningTests {

    @Test func `should keep the strict preset low-latency without setting a frame delay`() {
        let tuning = H264Tuning.strict
        #expect(tuning.realTime)
        #expect(!tuning.allowFrameReordering)
        #expect(tuning.lowLatencyRateControl)
        #expect(tuning.maxFrameDelayCount == nil)
    }

    @Test func `should hold no frames and disable reordering in the low-latency preset`() {
        let t = H264Tuning.lowLatency
        #expect(t.realTime == true)
        #expect(t.allowFrameReordering == false)
        #expect(t.maxFrameDelayCount == 0)
        #expect(t.lowLatencyRateControl == true)
    }

    @Test func `should space keyframes five seconds apart at 60fps`() {
        #expect(H264Tuning.lowLatency.maxKeyFrameInterval(fps: 60) == 300)
    }

    @Test func `should scale the keyframe interval with the capture rate`() {
        #expect(H264Tuning.lowLatency.maxKeyFrameInterval(fps: 30) == 150)
    }

    @Test func `should keep a non-zero keyframe interval when the capture rate is zero`() {
        #expect(H264Tuning.lowLatency.maxKeyFrameInterval(fps: 0) == 5)
    }

    @Test func `should ask the encoder for every property a low-latency tuning sets`() {
        #expect(H264Tuning.lowLatency.properties(bitrate: 2_000_000, fps: 30, profile: .highProfileAutoLevel) == [
            .realTime(true), .highProfileAutoLevel, .allowFrameReordering(false),
            .averageBitRate(2_000_000), .expectedFrameRate(30), .maxKeyFrameInterval(150),
            .maxFrameDelayCount(0),
        ])
    }

    @Test func `should leave the frame delay to the encoder when the tuning sets none`() {
        #expect(!H264Tuning.strict.properties(bitrate: 1, fps: 30, profile: .highProfileAutoLevel).contains(.maxFrameDelayCount(0)))
    }

    @Test func `should retune only the rate and the keyframe spacing when the frame rate changes`() {
        #expect(H264Tuning.lowLatency.frameRateProperties(fps: 60) == [
            .expectedFrameRate(60), .maxKeyFrameInterval(300),
        ])
    }
}
