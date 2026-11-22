import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// The Mac family as a source of `Devices`: each display attached to this Mac,
/// as CoreGraphics lists it, a device you can watch and drive.
@Suite("MacDisplays")
struct MacDisplaysTests {
    static let builtIn = MacDisplayInfo(
        id: 1, uuid: "37D8832A-2D66-02CA-B9F7-8F30A301B230", name: "Built-in Retina Display", isMain: true,
        bounds: Rect(origin: Point(x: 0, y: 0), size: Size(width: 1512, height: 982)))
    static let studio = MacDisplayInfo(
        id: 2, uuid: "9E1F2A10-0000-4000-8000-00000000ABCD", name: "Studio Display", isMain: false,
        bounds: Rect(origin: Point(x: 1512, y: 0), size: Size(width: 2560, height: 1440)))

    func devices(_ displays: [MacDisplayInfo]) -> MacDisplays {
        MacDisplays(displays: { displays }, feed: { MockDisplayFeed() }, events: MockHostEvents())
    }

    @Test func `should list each display attached to the Mac as a physical macOS device`() {
        let all = devices([Self.builtIn, Self.studio]).all
        #expect(all.map(\.id) == [DeviceID(Self.builtIn.uuid), DeviceID(Self.studio.uuid)])
        #expect(all.map(\.name) == ["Built-in Retina Display", "Studio Display"])
        #expect(all.map(\.kind) == [
            DeviceKind(platform: .macOS, reality: .physical, model: "Built-in Retina Display"),
            DeviceKind(platform: .macOS, reality: .physical, model: "Studio Display"),
        ])
        #expect(all.map(\.state) == [.ready, .ready])
    }

    @Test func `should list no displays when the Mac reports none`() {
        #expect(devices([]).all.isEmpty)
    }

    @Test func `should find a display by its own UUID`() throws {
        let found = try devices([Self.builtIn, Self.studio]).find(id: DeviceID(Self.studio.uuid))
        #expect(found?.name == "Studio Display")
    }

    @Test func `should find nothing when no display has the id`() throws {
        #expect(try devices([Self.builtIn]).find(id: "nope") == nil)
    }

    @Test func `should let a display be watched, touched, hovered, scrolled and typed on`() {
        let display = devices([Self.studio]).all[0]
        #expect(display.abilities.names == ["screen", "touch", "pointer", "scroll", "key", "type"])
    }

    @Test func `should land a display's touches on its own place on the desktop`() throws {
        let display = devices([Self.studio]).all[0]
        let input = try #require(try display.abilities.require(.touch) as? MacInput)
        #expect(input.display() == DisplayEvents(bounds: Self.studio.bounds))
    }

    @Test func `should land a display's touches where it is now when the displays were rearranged since`() throws {
        let moved = MacDisplayInfo(
            id: 2, uuid: Self.studio.uuid, name: "Studio Display", isMain: true,
            bounds: Rect(origin: Point(x: 0, y: 0), size: Size(width: 2560, height: 1440)))
        let listed = Listed([Self.builtIn, Self.studio])
        let mac = MacDisplays(displays: { listed.now }, feed: { MockDisplayFeed() }, events: MockHostEvents())
        let input = try #require(try mac.find(id: DeviceID(Self.studio.uuid))?.abilities.require(.touch) as? MacInput)
        listed.now = [moved, Self.builtIn]   // the studio made main: every origin moves
        #expect(input.display() == DisplayEvents(bounds: moved.bounds))
    }

    final class Listed: @unchecked Sendable {
        private let lock = NSLock()
        private var displays: [MacDisplayInfo]
        init(_ displays: [MacDisplayInfo]) { self.displays = displays }
        var now: [MacDisplayInfo] {
            get { lock.withLock { displays } }
            set { lock.withLock { displays = newValue } }
        }
    }
}
