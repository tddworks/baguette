import Testing
import Foundation
import Mockable
@testable import Baguette

@Suite("Accessibility")
struct AccessibilityTests {

    @Test func `simulator delegates accessibility() to the host`() {
        let host = MockSimulators()
        let stubAX = MockAccessibility()
        given(host).accessibility(for: .any).willReturn(stubAX)

        let sim = Simulator(udid: "u1", name: "X", state: .booted, host: host)

        let ax = sim.accessibility()
        #expect(ax === stubAX)
        verify(host).accessibility(for: .value(sim)).called(1)
    }

    @Test func `describeAll returns the host's tree`() throws {
        let ax = MockAccessibility()
        let tree = AXNode(
            role: "AXApplication",
            label: "Settings",
            frame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 390, height: 844)),
            children: [
                AXNode(role: "AXButton", label: "OK",
                       frame: Rect(origin: Point(x: 10, y: 20), size: Size(width: 80, height: 30)))
            ]
        )
        given(ax).describeAll().willReturn(tree)

        let result = try ax.describeAll()
        #expect(result?.role == "AXApplication")
        #expect(result?.children.count == 1)
        verify(ax).describeAll().called(1)
    }

    @Test func `describeAt returns the host's hit-tested node`() throws {
        let ax = MockAccessibility()
        let node = AXNode(
            role: "AXButton", label: "OK",
            frame: Rect(origin: Point(x: 10, y: 20), size: Size(width: 80, height: 30))
        )
        given(ax).describeAt(point: .any).willReturn(node)

        let result = try ax.describeAt(point: Point(x: 50, y: 35))
        #expect(result?.label == "OK")
        verify(ax).describeAt(point: .value(Point(x: 50, y: 35))).called(1)
    }
}
