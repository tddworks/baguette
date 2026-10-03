import Testing
import VideoToolbox

@testable import Baguette

@Suite("H264 reference chain")
struct H264ReferenceChainTests {
    @Test func `normal VideoToolbox drops produce no frame while actual errors propagate`() throws {
        let encoder = H264Encoder(fps: 20)
        for flags in [VTEncodeInfoFlags.frameDropped, []] {
            #expect(try encoder.output(generation: 0, status: noErr, flags: flags, sampleBuffer: nil).get() == nil)
        }
        #expect(throws: (any Error).self) {
            try encoder.output(generation: 0, status: kVTInvalidSessionErr, flags: [], sampleBuffer: nil).get()
        }
        encoder.stop()
        #expect(
            try encoder.output(generation: 0, status: kVTInvalidSessionErr, flags: [], sampleBuffer: nil).get() == nil)
    }

    @Test func `a replacement session rejects old callbacks and waits for its own decoder configuration`() {
        var chain = H264ReferenceChain()
        let old = chain.generation
        let accepted1 = chain.accepts(generation: old, keyframe: true, hasDescription: true)
        #expect(accepted1)
        chain.reset()
        let accepted2 = chain.accepts(generation: old, keyframe: true, hasDescription: true)
        #expect(!accepted2)
        #expect(chain.needsKeyframe)
        let accepted3 = chain.accepts(generation: chain.generation, keyframe: false, hasDescription: false)
        #expect(!accepted3)
        let accepted4 = chain.accepts(generation: chain.generation, keyframe: true, hasDescription: false)
        #expect(!accepted4)
        let accepted5 = chain.accepts(generation: chain.generation, keyframe: true, hasDescription: true)
        #expect(accepted5)
        #expect(!chain.needsKeyframe)
        let accepted6 = chain.accepts(generation: chain.generation, keyframe: false, hasDescription: false)
        #expect(accepted6)
    }
}
