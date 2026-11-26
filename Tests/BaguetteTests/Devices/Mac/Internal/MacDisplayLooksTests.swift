import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// How a Mac display looks before a frame is picked: no frame — a clear
/// picture its own shape, the screen filling it.
@Suite("MacDisplayLooks")
struct MacDisplayLooksTests {
    static let dell = MacDisplayInfo(
        id: 2, uuid: "D", name: "DELL UP2716D", isMain: false,
        bounds: Rect(origin: Point(x: 1440, y: 595), size: Size(width: 2560, height: 1440)))

    final class Pictures: @unchecked Sendable {
        private let lock = NSLock()
        private var _asked: [Size] = []
        var asked: [Size] { lock.withLock { _asked } }
        func clear(_ size: Size) -> Data? { lock.withLock { _asked.append(size) }; return Data("clear".utf8) }
    }

    @Test func `should show a display with no frame, the screen filling a clear picture its own size`() throws {
        let pictures = Pictures()
        let looks = MacDisplayLooks(displays: { [Self.dell] }, clearPicture: pictures.clear)

        let assets = try #require(looks.assets(forDeviceName: "DELL UP2716D"))

        #expect(assets.composite == ChromeImage(data: Data("clear".utf8), size: Size(width: 2560, height: 1440)))
        #expect(assets.chrome.screenRect(in: assets.composite.size)
            == Rect(origin: Point(x: 0, y: 0), size: Size(width: 2560, height: 1440)))
        #expect(assets.chrome.outerCornerRadius == 0)
        #expect(assets.chrome.buttons.isEmpty)
        #expect(pictures.asked == [Size(width: 2560, height: 1440)])
    }

    @Test func `should show no look for a name no display has`() {
        let looks = MacDisplayLooks(displays: { [Self.dell] }, clearPicture: Pictures().clear)
        #expect(looks.assets(forDeviceName: "iPhone 17 Pro") == nil)
        #expect(looks.panels(forDeviceName: "iPhone 17 Pro").isEmpty)
    }

    @Test func `should give a display one panel, never an unfolded one`() {
        let looks = MacDisplayLooks(displays: { [Self.dell] }, clearPicture: Pictures().clear)
        #expect(looks.panels(forDeviceName: "DELL UP2716D") == [.primary])
        #expect(looks.assets(forDeviceName: "DELL UP2716D", panel: .secondary) == nil)
    }
}
