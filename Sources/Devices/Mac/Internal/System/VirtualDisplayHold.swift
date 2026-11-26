import AppKit
import BaguetteDevice
import CoreGraphics

/// One display no cable connects, made in this process through CoreGraphics'
/// private `CGVirtualDisplay` (the API DeskPad and BetterDisplay use) and kept
/// while the process lives. Integration-only: its shape is `SharedScreenShape`'s
/// and its own mode `SharedScreenShape.isMode`. Measured on macOS 27: the
/// display takes its modes once and starts on the 1× one; only the first
/// virtual display a process makes can have its mode chosen.
public enum VirtualDisplayHold {
    private typealias Make = @convention(c) (Unmanaged<AnyObject>, Selector, UInt32, UInt32, Double) -> Unmanaged<AnyObject>
    private typealias Initialise = @convention(c) (Unmanaged<AnyObject>, Selector, AnyObject) -> Unmanaged<AnyObject>
    private typealias Apply = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
    nonisolated(unsafe) private static var held: NSObject?
    private static let queue = DispatchQueue(label: "baguette.mac.virtual-display")

    /// Make it and choose its 2× mode: what to announce.
    public static func make(named name: String, shape: SharedScreenShape, serial: UInt32) -> VirtualDisplayAnnouncement {
        guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let displayClass = NSClassFromString("CGVirtualDisplay"),
              let modeClass = NSClassFromString("CGVirtualDisplayMode") else { return .failed("no CGVirtualDisplay on this Mac") }
        let made: (NSObject, UInt32)? = autoreleasepool {
            let descriptor = descriptorClass.init()
            descriptor.setValue(queue, forKey: "queue")
            descriptor.setValue(name, forKey: "name")
            descriptor.setValue(UInt32(shape.pixels.width), forKey: "maxPixelsWide")
            descriptor.setValue(UInt32(shape.pixels.height), forKey: "maxPixelsHigh")
            descriptor.setValue(NSValue(size: NSSize(width: shape.pixels.width / 8.7, height: shape.pixels.height / 8.7)),
                                forKey: "sizeInMillimeters")   // ~220 pixels an inch
            descriptor.setValue(0xBA6E, forKey: "vendorID")
            descriptor.setValue(0xBA6E, forKey: "productID")
            descriptor.setValue(serial, forKey: "serialNum")    // the UUID follows from these three
            let initialise = NSSelectorFromString("initWithDescriptor:")
            guard let display = unsafeBitCast(class_getMethodImplementation(displayClass, initialise), to: Initialise.self)(
                alloc(displayClass), initialise, descriptor).takeRetainedValue() as? NSObject,
                  let id = (display.value(forKey: "displayID") as? NSNumber)?.uint32Value, id != 0 else { return nil }
            let make = NSSelectorFromString("initWithWidth:height:refreshRate:")
            let mode = unsafeBitCast(class_getMethodImplementation(modeClass, make), to: Make.self)(
                alloc(modeClass), make, UInt32(shape.points.width), UInt32(shape.points.height), 60).takeRetainedValue()
            let settings = settingsClass.init()
            settings.setValue(1, forKey: "hiDPI")
            settings.setValue([mode], forKey: "modes")
            let apply = NSSelectorFromString("applySettings:")
            guard unsafeBitCast(class_getMethodImplementation(displayClass, apply), to: Apply.self)(display, apply, settings)
            else { return nil }
            return (display, id)
        }
        guard let (display, id) = made else { return .failed("the Mac didn't make the display") }
        held = display
        guard choose(shape, on: id) else { return .failed("the display never offered its 2x mode") }
        let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
        return uuid.map { .ready(id: id, uuid: $0) } ?? .failed("the display has no UUID")
    }

    /// The display's own 2× mode, once macOS offers it: 2 s at most.
    private static func choose(_ shape: SharedScreenShape, on id: UInt32) -> Bool {
        for _ in 0..<40 {
            let modes = CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary)
                as? [CGDisplayMode] ?? []
            if let own = modes.first(where: {
                shape.isMode(width: $0.width, height: $0.height, pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight)
            }) { return CGDisplaySetDisplayMode(id, own, nil) == .success }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    private static func alloc(_ type: AnyClass) -> Unmanaged<AnyObject> {
        (type as AnyObject).perform(NSSelectorFromString("alloc"))
    }
}
