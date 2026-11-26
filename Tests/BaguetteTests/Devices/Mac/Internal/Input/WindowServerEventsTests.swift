import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// Events told to the Mac's window server: in order with their pauses kept,
/// none while this process isn't trusted for Accessibility — asked once, and
/// never asked again once it is.
@Suite("WindowServerEvents")
struct WindowServerEventsTests {
    final class Recorded: @unchecked Sendable {
        private let lock = NSLock()
        private var _items: [String] = []
        var items: [String] { lock.withLock { _items } }
        func add(_ item: String) { lock.withLock { _items.append(item) } }
    }

    let server = MockWindowServer()
    let told = Recorded()

    func events(trusted: [Bool]) -> WindowServerEvents {
        var answers = trusted
        let told = told
        given(server).trusted(asking: .any).willProduce { asking in
            told.add("trusted?\(asking ? " asking" : "")")
            return answers.isEmpty ? false : answers.removeFirst()
        }
        given(server).post(.any).willProduce { told.add("\($0)") }
        return WindowServerEvents(server: server, pause: { told.add("pause \($0)") })
    }

    @Test func `should tell the window server each event in order, keeping its pauses`() {
        let at = Point(x: 10, y: 20)
        #expect(events(trusted: [true]).post([.mouseDown(at), .pause(0.1), .mouseUp(at)]))
        #expect(told.items == ["trusted? asking", "\(HostEvent.mouseDown(at))", "pause 0.1", "\(HostEvent.mouseUp(at))"])
    }

    @Test func `should tell the window server nothing when this process isn't trusted for Accessibility`() {
        #expect(!events(trusted: [false]).post([.mouseDown(Point(x: 1, y: 1))]))
        #expect(told.items == ["trusted? asking"])
    }

    @Test func `should ask for Accessibility once, however often it is refused`() {
        let mac = events(trusted: [false, false])
        _ = mac.post([.mouseMoved(Point(x: 1, y: 1))])
        _ = mac.post([.mouseMoved(Point(x: 1, y: 1))])
        #expect(told.items == ["trusted? asking", "trusted?"])
    }

    @Test func `should not ask again once this process is trusted`() {
        let mac = events(trusted: [true])
        _ = mac.post([])
        _ = mac.post([])
        #expect(told.items == ["trusted? asking"])
    }
}
