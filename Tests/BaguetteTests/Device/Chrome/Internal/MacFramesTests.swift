import Foundation
import Mockable
import Testing
@testable import BaguetteDevice

/// The Mac frames installed in a frames folder, as bezels a device can be
/// shown in: each measured frame whose picture is in the folder.
@Suite("MacFrames")
struct MacFramesTests {
    static let folder = URL(fileURLWithPath: "/frames")
    static let picture = Data("png".utf8)

    func frames(installed: [String]) -> MacFrames {
        MacFrames(folder: Self.folder) { url in
            installed.map { Self.folder.appendingPathComponent("\($0).png") }.contains(url) ? Self.picture : nil
        }
    }

    @Test func `should show a measured frame's picture as the bezel, the screen at its opening`() throws {
        let assets = try #require(frames(installed: ["iMac 27-inch"]).assets(forDeviceName: "iMac 27-inch"))
        let iMac = try #require(MacFrame.named("iMac 27-inch"))
        #expect(assets.composite == ChromeImage(data: Self.picture, size: iMac.image))
        #expect(assets.bareComposite == assets.composite)
        #expect(assets.chrome == iMac.chrome)
        #expect(assets.screenMask == nil)
    }

    @Test func `should show no bezel when the frame's picture isn't installed`() {
        #expect(frames(installed: []).assets(forDeviceName: "iMac 27-inch") == nil)
        #expect(frames(installed: []).panels(forDeviceName: "iMac 27-inch").isEmpty)
    }

    @Test func `should show no bezel for a name no frame was measured for`() {
        #expect(frames(installed: ["iPhone 17 Pro"]).assets(forDeviceName: "iPhone 17 Pro") == nil)
    }

    @Test func `should give a frame one panel, never an unfolded one`() {
        let installed = frames(installed: ["iMac 27-inch"])
        #expect(installed.panels(forDeviceName: "iMac 27-inch") == [.primary])
        #expect(installed.assets(forDeviceName: "iMac 27-inch", panel: .secondary) == nil)
    }

    @Test func `should list the installed frames a display fits`() {
        let installed = frames(installed: ["iMac 27-inch", "MacBook Pro 14-inch (M4)"])
        #expect(installed.fitting(Size(width: 2560, height: 1440)).map(\.name) == ["iMac 27-inch"])
    }
}

/// DeviceKit's chrome first, then the Mac frames: one `Chromes` the page asks.
@Suite("CombinedChromes")
struct CombinedChromesTests {
    static let assets = DeviceChromeAssets(
        chrome: DeviceChrome(identifier: "phone", screenInsets: Insets(top: 1, left: 1, bottom: 1, right: 1),
                             outerCornerRadius: 0, buttons: [], compositeImageName: nil),
        composite: ChromeImage(data: Data(), size: Size(width: 10, height: 10)))

    @Test func `should take a bezel from the first source that has it`() {
        let deviceKit = MockChromes()
        given(deviceKit).assets(forDeviceName: .value("iPhone 17 Pro")).willReturn(Self.assets)
        given(deviceKit).assets(forDeviceName: .value("iMac 27-inch")).willReturn(nil)
        let mac = MockChromes()
        given(mac).assets(forDeviceName: .any).willReturn(Self.assets)
        let chromes = CombinedChromes([deviceKit, mac])

        #expect(chromes.assets(forDeviceName: "iPhone 17 Pro") == Self.assets)
        #expect(chromes.assets(forDeviceName: "iMac 27-inch") == Self.assets)
        verify(mac).assets(forDeviceName: .value("iPhone 17 Pro")).called(0)
    }

    @Test func `should take a device's panels and a panel's bezel from the first source that has them`() {
        let deviceKit = MockChromes()
        given(deviceKit).panels(forDeviceName: .any).willReturn([])
        given(deviceKit).assets(forDeviceName: .any, panel: .any).willReturn(nil)
        let mac = MockChromes()
        given(mac).panels(forDeviceName: .any).willReturn([.primary])
        given(mac).assets(forDeviceName: .any, panel: .any).willReturn(Self.assets)
        let chromes = CombinedChromes([deviceKit, mac])

        #expect(chromes.panels(forDeviceName: "iMac 27-inch") == [.primary])
        #expect(chromes.assets(forDeviceName: "iMac 27-inch", panel: .primary) == Self.assets)
    }
}
