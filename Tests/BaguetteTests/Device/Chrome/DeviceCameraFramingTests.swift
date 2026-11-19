import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDevice

@Suite("DeviceCameraFraming")
struct DeviceCameraFramingTests {
    @Test func `should fit the complete device through a standard perspective lens`() {
        let framing = DeviceCameraFraming.fit(
            subjectWidth: 2.2,
            subjectHeight: 4.4,
            subjectDepth: 0.2,
            viewport: RenderDimensions(width: 320, height: 240)
        )
        let expectedDistance = 0.3 + (4.4 * 1.15 / 2) / tan(16 * .pi / 180)

        #expect(framing.fieldOfViewDegrees == 32)
        #expect(abs(framing.distanceFromCenter - expectedDistance) < 0.000_001)
    }

    @Test func `should zoom by moving the camera while keeping its lens`() {
        let framing = DeviceCameraFraming.fit(
            subjectWidth: 2.2,
            subjectHeight: 4.4,
            subjectDepth: 0.2,
            viewport: RenderDimensions(width: 320, height: 240)
        )

        #expect(framing.distance(at: 2) == framing.distanceFromCenter / 2)
        #expect(framing.fieldOfViewDegrees == 32)
    }

    @Test func `should fit the width when a device is wider than its viewport`() {
        let framing = DeviceCameraFraming.fit(
            subjectWidth: 4,
            subjectHeight: 2,
            subjectDepth: 0.4,
            viewport: RenderDimensions(width: 200, height: 400)
        )
        let requiredHeight = 4 / 0.5
        let expectedDistance = 0.6 + (requiredHeight * 1.15 / 2) / tan(16 * .pi / 180)

        #expect(abs(framing.distanceFromCenter - expectedDistance) < 0.000_001)
    }
}
