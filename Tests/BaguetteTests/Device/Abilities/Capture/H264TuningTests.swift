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
}
