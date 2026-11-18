import Testing
@testable import Baguette

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
    }
}
