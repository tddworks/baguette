import Testing
@testable import Baguette
@testable import BaguetteDevice

@Suite("UnableAccessibility")
struct UnableAccessibilityTests {
    private let refusal = DeviceError.unable(ability: "accessibility", device: "han's iPhone")

    @Test func `should answer every read of the screen with the device's refusal`() {
        let accessibility = UnableAccessibility(refusal)

        #expect(throws: refusal) { try accessibility.describeAll() }
        #expect(throws: refusal) { try accessibility.glance() }
        #expect(throws: refusal) { try accessibility.describeAt(point: Point(x: 1, y: 1)) }
    }

    @Test func `should press and wake nothing, answering with the refusal`() {
        let accessibility = UnableAccessibility(refusal)

        #expect(throws: refusal) { try accessibility.wake() }
        #expect(throws: refusal) {
            try accessibility.press(AXNode(role: "AXButton", frame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 1, height: 1))))
        }
    }
}
