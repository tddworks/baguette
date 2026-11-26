import Foundation
import Testing

@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

@Suite("SimulatorKitScreenOrientation")
struct SimulatorKitScreenOrientationTests {
    @Test(arguments: [
        (UInt32(1), DeviceOrientation.portrait),
        (2, .portraitUpsideDown),
        (3, .landscapeLeft),
        (4, .landscapeRight),
    ])
    func `should read each simulator orientation as its measured native rotation`(
        raw: UInt32, expected: DeviceOrientation
    ) throws {
        #expect(try SimulatorKitScreenOrientation.read(properties: ScreenProperties(raw)) == expected)
    }

    @Test(arguments: [UInt32(0), 5, .max])
    func `should reject an unknown orientation rather than assume portrait`(raw: UInt32) {
        #expect(throws: SimulatorKitScreenOrientation.Failure.unknown(raw)) {
            try SimulatorKitScreenOrientation.read(properties: ScreenProperties(raw))
        }
    }

    @Test func `should fail when the screen properties are missing`() {
        #expect(throws: SimulatorKitScreenOrientation.Failure.unavailable) {
            try SimulatorKitScreenOrientation.read(properties: NSObject())
        }
    }

    @Test func `should describe the screen identity, pixels, points and rotation from one snapshot`() throws {
        let properties = LiveProperties()
        let screen = try SimulatorKitScreenOrientation.readScreen(properties: properties, panel: nil)
        #expect(
            screen
                == AXScreen(
                    width: 402, height: 874, orientation: .portrait,
                    target: ScreenTarget(screenId: 1, litPanel: nil, pixelSize: Size(width: 1206, height: 2622))))

        properties.pixelSize = CGSize(width: 744, height: 1133)
        properties.screenID = 2
        properties.uiOrientation = 3
        properties.currentMode.preferredUIScale = 1
        let changed = try SimulatorKitScreenOrientation.readScreen(properties: properties, panel: .secondary)
        #expect(changed.width == 744)
        #expect(changed.orientation == .landscapeLeft)
        #expect(changed.target == ScreenTarget(screenId: 2, litPanel: .secondary, pixelSize: Size(width: 744, height: 1133)))
    }

    @Test func `should fail when the screen properties have no current mode`() {
        #expect(throws: SimulatorKitScreenOrientation.Failure.unavailable) {
            try SimulatorKitScreenOrientation.readScreen(properties: ModelessProperties(), panel: nil)
        }
    }

    @Test func `should say coordinate conversion is unavailable when the orientation cannot be read`() {
        #expect(
            SimulatorKitScreenOrientation.Failure.unavailable.errorDescription
                == "SimulatorKit cannot report the screen's interface orientation; coordinate conversion is unavailable.")
        #expect(
            SimulatorKitScreenOrientation.Failure.unknown(9).errorDescription
                == "SimulatorKit reported unknown interface orientation 9; coordinate conversion is unavailable.")
    }

    @Test func `should reject a screen with a zero scale rather than divide by it`() {
        let properties = LiveProperties()
        properties.currentMode.preferredUIScale = 0
        #expect(throws: SimulatorKitScreenOrientation.Failure.unavailable) {
            try SimulatorKitScreenOrientation.readScreen(properties: properties, panel: nil)
        }
    }
}

private final class LiveMode: NSObject {
    @objc dynamic var preferredUIScale: Double = 3
}

private final class LiveProperties: NSObject {
    @objc dynamic var pixelSize = CGSize(width: 1206, height: 2622)
    @objc dynamic var screenID: UInt32 = 1
    @objc dynamic var uiOrientation: UInt32 = 1
    @objc dynamic var currentMode = LiveMode()
}

private final class ModelessProperties: NSObject {
    @objc dynamic var pixelSize = CGSize(width: 1206, height: 2622)
    @objc dynamic var screenID: UInt32 = 1
}

private final class ScreenProperties: NSObject {
    private let orientation: UInt32

    init(_ orientation: UInt32) { self.orientation = orientation }

    @objc dynamic func uiOrientation() -> UInt32 { orientation }
}
