import Testing
@testable import Baguette
@testable import BaguetteDevice

/// An Android device's screen in pixels, as `adb shell wm size` says.
@Suite("AndroidScreenSize")
struct AndroidScreenSizeTests {
    @Test func `should read the screen's physical size`() {
        #expect(AndroidScreenSize.pixels(fromWmSize: "Physical size: 1080x2400\n") == Size(width: 1080, height: 2400))
    }

    @Test func `should read the size an override sets over the physical one`() {
        #expect(AndroidScreenSize.pixels(fromWmSize: "Physical size: 1080x2400\nOverride size: 720x1600\n")
            == Size(width: 720, height: 1600))
    }

    @Test func `should read no size from anything else`() {
        #expect(AndroidScreenSize.pixels(fromWmSize: "error: device offline") == nil)
    }

    @Test func `should read how many pixels make one point from the screen's density`() {
        #expect(AndroidScreenSize.pixelsPerPoint(fromWmDensity: "Physical density: 420\n") == 2.625)
        #expect(AndroidScreenSize.pixelsPerPoint(fromWmDensity: "Physical density: 420\nOverride density: 320\n") == 2)
        #expect(AndroidScreenSize.pixelsPerPoint(fromWmDensity: "nonsense") == nil)
    }
}
