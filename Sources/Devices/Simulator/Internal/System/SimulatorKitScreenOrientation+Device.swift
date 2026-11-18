import BaguetteDevice
import Foundation
import ObjectiveC

/// The live fetch: a `SimulatorKit.SimDeviceScreen` for the device's screen,
/// and its `screenProperties` snapshot. What the snapshot says is read by
/// `read(properties:)` / `readScreen(properties:panel:)`.
extension SimulatorKitScreenOrientation {
    static func read(device: NSObject, screenID: UInt32) throws -> DeviceOrientation {
        try read(properties: properties(device: device, screenID: screenID))
    }

    static func readScreen(device: NSObject, screenID: UInt32, panel: IntegratedPanel?) throws -> AXScreen {
        try readScreen(properties: properties(device: device, screenID: screenID), panel: panel)
    }

    private static func properties(device: NSObject, screenID: UInt32) throws -> NSObject {
        let allocSelector = NSSelectorFromString("alloc")
        let initSelector = NSSelectorFromString("initWithDevice:screenID:")
        guard let cls = NSClassFromString("SimulatorKit.SimDeviceScreen"),
            let alloc = class_getClassMethod(cls, allocSelector),
            let initialize = class_getInstanceMethod(cls, initSelector)
        else { throw Failure.unavailable }

        // IMP calls do not carry ObjC's alloc/init ownership annotations.
        // Transfer the +1 allocation through init, then adopt it exactly once.
        typealias Allocate = @convention(c) (AnyClass, Selector) -> Unmanaged<NSObject>?
        guard let instance = unsafeBitCast(method_getImplementation(alloc), to: Allocate.self)(cls, allocSelector)
        else { throw Failure.unavailable }

        typealias Initialize = @convention(c) (Unmanaged<NSObject>, Selector, AnyObject, UInt32) -> Unmanaged<NSObject>?
        guard
            let display = unsafeBitCast(method_getImplementation(initialize), to: Initialize.self)(
                instance, initSelector, device, screenID)?.takeRetainedValue(),
            let screen = object(display, selector: "screen"),
            let properties = object(screen, selector: "screenProperties")
        else { throw Failure.unavailable }
        return properties
    }
}
