import Testing
import VideoToolbox

@testable import Baguette
@testable import BaguetteDevice

@Suite("H264 reference chain")
struct H264ReferenceChainTests {
    @Test func `should produce no frame for a normal encoder drop but surface a real encoder error until stopped`() throws {
        let encoder = H264Encoder(fps: 20)
        for dropped in [true, false] {
            let result = CompressionResult(status: 0, dropped: dropped, frame: nil)
            #expect(try encoder.output(generation: 0, result: result).get() == nil)
        }
        let failed = CompressionResult(status: kVTInvalidSessionErr, dropped: false, frame: nil)
        #expect(throws: (any Error).self) { try encoder.output(generation: 0, result: failed).get() }
        encoder.stop()
        #expect(try encoder.output(generation: 0, result: failed).get() == nil)
    }

    @Test func `should ignore an old session's frames and wait for a keyframe with its own description when the session is replaced`() {
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
