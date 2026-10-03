import Foundation
import Testing

@testable import Baguette

@Suite("SimulatorKitScreenOrientation")
struct SimulatorKitScreenOrientationTests {
    @Test(arguments: [
        (UInt32(1), DeviceOrientation.portrait),
        (2, .portraitUpsideDown),
        (3, .landscapeLeft),
        (4, .landscapeRight),
    ])
    func `SimulatorKit orientation is mapped to the measured native rotation`(
        raw: UInt32, expected: DeviceOrientation
    ) throws {
        #expect(try SimulatorKitScreenOrientation.read(properties: ScreenProperties(raw)) == expected)
    }

    @Test(arguments: [UInt32(0), 5, .max])
    func `unknown orientation fails instead of assuming portrait`(raw: UInt32) {
        #expect(throws: SimulatorKitScreenOrientation.Failure.unknown(raw)) {
            try SimulatorKitScreenOrientation.read(properties: ScreenProperties(raw))
        }
    }

    @Test func `missing screen properties fail explicitly`() {
        #expect(throws: SimulatorKitScreenOrientation.Failure.unavailable) {
            try SimulatorKitScreenOrientation.read(properties: NSObject())
        }
    }

    @Test func `readScreen reports identity pixels points and rotation from one properties snapshot`() throws {
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

    @Test func `readScreen rejects a zero scale instead of dividing by it`() {
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

private final class ScreenProperties: NSObject {
    private let orientation: UInt32

    init(_ orientation: UInt32) { self.orientation = orientation }

    @objc dynamic func uiOrientation() -> UInt32 { orientation }
}
