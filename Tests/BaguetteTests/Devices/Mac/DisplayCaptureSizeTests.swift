import Testing
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// The picture a Mac display is captured at: its pixels, never more than the
/// hardware H.264 encoder can take on its long side.
@Suite("DisplayCaptureSize")
struct DisplayCaptureSizeTests {
    @Test func `should capture a display at its pixels`() {
        let size = DisplayCaptureSize(points: Size(width: 1512, height: 982), pixelsPerPoint: 2)
        #expect(size.pixels == Size(width: 3024, height: 1964))
    }

    @Test func `should cap a 5K display's stream at 4096 pixels on its long side`() {
        let size = DisplayCaptureSize(points: Size(width: 2560, height: 1440), pixelsPerPoint: 2)
        #expect(size.pixels == Size(width: 4096, height: 2304))
    }

    @Test func `should cap a portrait display on its height when it is the long side`() {
        let size = DisplayCaptureSize(points: Size(width: 1440, height: 2560), pixelsPerPoint: 2)
        #expect(size.pixels == Size(width: 2304, height: 4096))
    }

    @Test func `should keep both sides even when the cap lands on an odd pixel`() {
        // 3400 × 4096 / 6000 = 2321.07 — down to the even 2320.
        let size = DisplayCaptureSize(points: Size(width: 3000, height: 1700), pixelsPerPoint: 2)
        #expect(size.pixels == Size(width: 4096, height: 2320))
    }
}
