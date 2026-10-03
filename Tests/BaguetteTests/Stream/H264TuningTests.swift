import Testing
@testable import Baguette

@Suite("H264Tuning")
struct H264TuningTests {

    @Test func `strict preset keeps low latency without the optional frame delay property`() {
        let tuning = H264Tuning.strict
        #expect(tuning.realTime)
        #expect(!tuning.allowFrameReordering)
        #expect(tuning.lowLatencyRateControl)
        #expect(tuning.maxFrameDelayCount == nil)
    }

    @Test func `low-latency preset holds no frames and disables reordering`() {
        let t = H264Tuning.lowLatency
        #expect(t.realTime == true)
        #expect(t.allowFrameReordering == false)
        #expect(t.maxFrameDelayCount == 0)
        #expect(t.lowLatencyRateControl == true)
    }

    @Test func `keyframe interval is five seconds of frames at 60fps`() {
        #expect(H264Tuning.lowLatency.maxKeyFrameInterval(fps: 60) == 300)
    }

    @Test func `keyframe interval scales with capture rate`() {
        #expect(H264Tuning.lowLatency.maxKeyFrameInterval(fps: 30) == 150)
    }

    @Test func `keyframe interval never collapses on a zero capture rate`() {
        #expect(H264Tuning.lowLatency.maxKeyFrameInterval(fps: 0) == 5)
    }
}
