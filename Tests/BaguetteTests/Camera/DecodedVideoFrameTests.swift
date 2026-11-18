import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

@Suite("DecodedVideoFrame")
struct DecodedVideoFrameTests {

    @Test func `should turn a decoded video frame into a camera frame with the given sequence and its own timestamp`() throws {
        let decoded = DecodedVideoFrame(
            pixels: Data(count: 16), width: 2, height: 2, presentationMs: 33
        )
        let frame = try decoded.frame(sequence: 5)
        #expect(frame.sequence == 5)
        #expect(frame.timestampMs == 33)
        #expect(frame.width == 2)
        #expect(frame.height == 2)
        #expect(frame.pixels.count == 16)
    }

    @Test func `should reject a decoded video frame when its pixels don't match its dimensions`() {
        let bad = DecodedVideoFrame(
            pixels: Data(count: 8), width: 2, height: 2, presentationMs: 0
        )
        #expect(throws: (any Error).self) {
            _ = try bad.frame(sequence: 1)
        }
    }

    // MARK: - Timestamp projection

    @Test func `should place a timestamp in seconds on the millisecond clock`() {
        #expect(DecodedVideoFrame.presentationMs(seconds: 0) == 0)
        #expect(DecodedVideoFrame.presentationMs(seconds: 1.5) == 1500)
        #expect(DecodedVideoFrame.presentationMs(seconds: 0.033) == 33)
    }

    /// A malformed asset reports an invalid / indefinite timestamp,
    /// which surfaces as a non-finite number of seconds. `UInt32.init`
    /// traps on those, so the projection has to answer instead — a
    /// bad file must not take the process down.
    @Test func `should place a non-finite timestamp at the start of the video`() {
        #expect(DecodedVideoFrame.presentationMs(seconds: .nan) == 0)
        #expect(DecodedVideoFrame.presentationMs(seconds: .infinity) == 0)
        #expect(DecodedVideoFrame.presentationMs(seconds: -.infinity) == 0)
    }

    @Test func `should place a timestamp before the video's start at zero`() {
        #expect(DecodedVideoFrame.presentationMs(seconds: -1) == 0)
    }

    /// `UInt32.init` traps just as hard on a finite-but-huge value, so
    /// `isNumeric`-style validation alone wouldn't be enough.
    @Test func `should saturate the millisecond clock when a timestamp is beyond it`() {
        #expect(DecodedVideoFrame.presentationMs(seconds: 1e21) == UInt32.max)
        #expect(DecodedVideoFrame.presentationMs(seconds: Double(UInt32.max)) == UInt32.max)
    }
}
