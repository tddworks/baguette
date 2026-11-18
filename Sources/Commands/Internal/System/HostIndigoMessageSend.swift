import BaguetteDevice
import Darwin
import Foundation
import ObjectiveC

extension HostIndigoMessages {
    /// Build (never send) a mouse-event message at (x, y) with the same
    /// legacy 9-arg signature `IndigoHIDInput` uses in production, `edge`
    /// in the x4 register: target 0x32 digitizer, event type 1 (down),
    /// NSSize 1×1; the trailing two doubles are unused.
    func mouse(x: Double, y: Double, edge: UInt32) -> [UInt8]? {
        let dev = CoreSimulators.developerDir()
        guard let kitPath = SimulatorKitFramework.path(developerDir: dev),
              let kit = dlopen(kitPath, RTLD_NOW),
              let sym = dlsym(kit, "IndigoHIDMessageForMouseNSEvent") else { return nil }
        typealias MouseFn = @convention(c) (
            UnsafePointer<CGPoint>, UnsafePointer<CGPoint>?,
            UInt32, UInt32, UInt32, Double, Double, Double, Double
        ) -> UnsafeMutableRawPointer?
        var point = CGPoint(x: x, y: y)
        let message = withUnsafePointer(to: &point) { at in
            unsafeBitCast(sym, to: MouseFn.self)(at, nil, 0x32, 1, edge, 1.0, 1.0, 1.0, 1.0)
        }
        guard let message else { return nil }
        defer { free(message) }
        let size = malloc_size(message)
        return Array(UnsafeBufferPointer(start: message.assumingMemoryBound(to: UInt8.self), count: size))
    }

    /// Send `message` via `SimDeviceLegacyHIDClient.send`, the path
    /// `IndigoHIDInput` takes in production; the client frees the copy.
    func send(_ message: [UInt8], udid: String, deviceSet: String?) -> Bool {
        let simulators = CoreSimulators(deviceSetPath: deviceSet)
        guard let device = simulators.resolveDevice(udid: udid),
              let cls = NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient") else { return false }
        let initSel = NSSelectorFromString("initWithDevice:error:")
        guard let imp = class_getMethodImplementation(cls, initSel) else { return false }
        typealias InitFn = @convention(c) (
            AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>
        ) -> AnyObject?
        let allocSel = NSSelectorFromString("alloc")
        guard let metaCls = object_getClass(cls),
              let allocImp = class_getMethodImplementation(metaCls, allocSel) else { return false }
        typealias AllocFn = @convention(c) (AnyClass, Selector) -> AnyObject?
        guard let allocated = unsafeBitCast(allocImp, to: AllocFn.self)(cls, allocSel) else { return false }
        var err: NSError?
        guard let client = unsafeBitCast(imp, to: InitFn.self)(allocated, initSel, device, &err) else { return false }

        let sendSel = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")
        guard let clientCls = object_getClass(client),
              let sendImp = class_getMethodImplementation(clientCls, sendSel) else { return false }
        typealias SendFn = @convention(c) (
            AnyObject, Selector, UnsafeMutableRawPointer, ObjCBool, AnyObject?, AnyObject?
        ) -> Void
        guard !message.isEmpty, let copy = malloc(message.count) else { return false }
        message.withUnsafeBytes { copy.copyMemory(from: $0.baseAddress!, byteCount: message.count) }
        let none: AnyObject? = nil
        unsafeBitCast(sendImp, to: SendFn.self)(client, sendSel, copy, ObjCBool(true), none, none)
        return true
    }
}
