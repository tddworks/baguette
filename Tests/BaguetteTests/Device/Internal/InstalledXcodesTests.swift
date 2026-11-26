import Foundation
import Testing
@testable import BaguetteDevice

/// The Xcodes on this Mac, in the order an asset that ships inside Xcode
/// is looked for: the selected one first, then the rest, newest first.
@Suite("Installed Xcodes")
struct InstalledXcodesTests {
    private static let x270 = URL(fileURLWithPath: "/Applications/Xcode-27.0.0.app")
    private static let x271 = URL(fileURLWithPath: "/Applications/Xcode-27.1.0-Beta.app")
    private static let x272 = URL(fileURLWithPath: "/Applications/Xcode-27.2.0.app")
    private static let x264 = URL(fileURLWithPath: "/Applications/Xcode-26.4.app")

    @Test func `should look in the selected Xcode first, then the others newest first`() {
        let order = Xcode.searchOrder(
            selected: Self.x270,
            installed: [(Self.x264, "26.4"), (Self.x271, "27.1"), (Self.x270, "27.0"), (Self.x272, "27.2")])

        #expect(order == [Self.x270, Self.x272, Self.x271, Self.x264])
    }

    @Test func `should compare versions by number, not by spelling`() {
        let x2610 = URL(fileURLWithPath: "/Applications/Xcode-26.10.app")
        let order = Xcode.searchOrder(selected: nil, installed: [(Self.x264, "26.4"), (x2610, "26.10")])

        #expect(order == [x2610, Self.x264])
    }

    @Test func `should list the selected Xcode once even when it is installed where the others are`() {
        let order = Xcode.searchOrder(selected: Self.x272, installed: [(Self.x272, "27.2")])

        #expect(order == [Self.x272])
    }
}
