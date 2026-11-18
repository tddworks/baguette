import Testing
@testable import Baguette
@testable import BaguetteDevice

@Suite("ScaleToFit")
struct ScaleToFitTests {

    @Test func `should leave a frame alone when it is already within the canvas cap`() {
        let fitted = ScaleToFit.fit(width: 800, height: 600, max: 1280)
        #expect(fitted.width == 800)
        #expect(fitted.height == 600)
    }

    @Test func `should shrink an oversized landscape frame so its long edge meets the cap`() {
        let fitted = ScaleToFit.fit(width: 1920, height: 1080, max: 1280)
        #expect(fitted.width == 1280)
        #expect(fitted.height == 720)
    }

    @Test func `should shrink an oversized portrait frame so its long edge meets the cap`() {
        let fitted = ScaleToFit.fit(width: 1080, height: 1920, max: 1280)
        #expect(fitted.width == 720)
        #expect(fitted.height == 1280)
    }

    @Test func `should shrink an oversized square frame to fill the cap exactly`() {
        let fitted = ScaleToFit.fit(width: 2560, height: 2560, max: 1280)
        #expect(fitted.width == 1280)
        #expect(fitted.height == 1280)
    }

    @Test func `should round the shorter edge rather than collapse it to zero`() {
        let fitted = ScaleToFit.fit(width: 1000, height: 3000, max: 1280)
        #expect(fitted.height == 1280)
        #expect(fitted.width == 427)  // round(1000 * 1280/3000)
    }
}
