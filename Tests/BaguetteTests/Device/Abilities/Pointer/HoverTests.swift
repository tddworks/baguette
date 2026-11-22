import Foundation
import Mockable
import Testing
@testable import BaguetteDevice

/// A pointer moving over the screen with no button down — what makes hover
/// effects, tooltips and an auto-hidden Dock respond on a Mac.
@Suite("Hover")
struct HoverTests {
    @Test func `should read where the pointer moved to, in device points beside the screen's size`() throws {
        let hover = try Hover.parse(["type": "hover", "x": 120.0, "y": 300.0, "width": 603.0, "height": 1311.0])
        #expect(hover == Hover(at: Point(x: 120, y: 300), size: Size(width: 603, height: 1311)))
    }

    @Test func `should refuse a hover that doesn't say where`() {
        #expect(throws: GestureError.self) { try Hover.parse(["type": "hover", "x": 1.0]) }
    }

    @Test func `should let a newer hover replace one still waiting`() {
        #expect(Hover(at: Point(x: 1, y: 1), size: Size(width: 10, height: 10)).isMotion)
    }

    @Test func `should move the device's pointer there`() {
        let pointer = MockPointer()
        given(pointer).move(to: .any, size: .any).willReturn(true)
        #expect(Hover(at: Point(x: 5, y: 6), size: Size(width: 10, height: 20)).execute(on: pointer))
        verify(pointer).move(to: .value(Point(x: 5, y: 6)), size: .value(Size(width: 10, height: 20))).called(1)
    }

    @Test func `should be a gesture every device's wire takes, refused where nothing points`() throws {
        let dispatcher = GestureDispatcher(input: Abilities(device: "iPhone"))
        #expect(dispatcher.move(line: #"{"type":"hover","x":1,"y":2,"width":10,"height":10}"#) == "hover")
        #expect(dispatcher.dispatch(line: #"{"type":"hover","x":1,"y":2,"width":10,"height":10}"#).contains("pointer"))
    }
}
