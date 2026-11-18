import BaguetteDevice
import Foundation
import ObjectiveC

/// `IndigoChannel` on SimulatorKit: a `SimDeviceLegacyHIDClient`, and each
/// message built by its own Indigo builder and sent with `IndigoHIDMessage`.
/// The mouse event alone is built on the main thread — it reads AppKit's
/// thread-local event state — and only the build hops there.
final class SimulatorKitIndigoChannel: IndigoChannel, @unchecked Sendable {
    private var functions: IndigoFunctions?
    private var client: AnyObject?

    func connect(to device: NSObject) -> Bool {
        if functions == nil { functions = IndigoFunctions.load() }
        guard let cls = NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient") else {
            logErr("SimDeviceLegacyHIDClient class not found")
            return false
        }
        let initSel = NSSelectorFromString("initWithDevice:error:")
        guard let imp = class_getMethodImplementation(cls, initSel) else { return false }
        typealias InitFn =
            @convention(c) (AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>) -> AnyObject?
        let initFn = unsafeBitCast(imp, to: InitFn.self)
        guard let metaCls = object_getClass(cls) else { return false }
        let allocSel = NSSelectorFromString("alloc")
        guard let allocImp = class_getMethodImplementation(metaCls, allocSel) else { return false }
        typealias AllocFn = @convention(c) (AnyClass, Selector) -> AnyObject?
        guard let allocated = unsafeBitCast(allocImp, to: AllocFn.self)(cls, allocSel) else { return false }
        var err: NSError?
        guard let made = initFn(allocated, initSel, device, &err) else {
            if let err { logErr("SimDeviceLegacyHIDClient init failed: \(err)") }
            return false
        }
        client = made
        return true
    }

    func send(_ message: IndigoMessage) -> IndigoDelivery {
        guard let client else { return .unavailable }
        if case .touch(let point, let identifier, let phase, let edge, let target) = message {
            let sent = IOHIDDigitizerDispatch.send(
                point: point, identifier: identifier, phase: phase, edge: edge, target: target, on: client)
            return sent ? .delivered : .undelivered
        }
        guard let functions else { return .unavailable }
        guard let built = Self.build(message, with: functions) else { return .unavailable }
        guard let raw = built else { return .unbuilt }
        return IndigoHIDMessage.send(raw, to: client) ? .delivered : .undelivered
    }

    /// `nil` when the builder is missing; `.some(nil)` when it built nothing.
    private static func build(
        _ message: IndigoMessage, with f: IndigoFunctions
    ) -> UnsafeMutableRawPointer?? {
        switch message {
        case .createPointerService: return f.createPointerService.map { $0() }
        case .createMouseService: return f.createMouseService.map { $0() }
        case .removePointerService: return f.removePointerService.map { $0() }
        case .createCarPlayService(let touch): return f.createCarPlayService.map { $0(touch ? 1 : 0) }
        case .removeCarPlayService: return f.removeCarPlayService.map { $0() }
        case .button(let code, let direction, let target): return f.button.map { $0(code, direction, target) }
        case .usage(let usage, let operation, let target):
            return f.hidArbitrary.map { $0(target, usage.page, usage.usage, operation) }
        case .scroll(let dx, let dy, let target): return f.scroll.map { $0(target, dx, dy, 0) }
        case .mouse(let first, let second, let target, let eventType, let direction, let size):
            return f.mouse.map { mfn in
                var pt1 = first
                guard var pt2 = second else {
                    return onMainThread {
                        withUnsafePointer(to: &pt1) { p1Ref in
                            mfn(p1Ref, nil, target, eventType, direction, 1.0, 1.0, size.width, size.height)
                        }
                    }
                }
                return onMainThread {
                    withUnsafePointer(to: &pt1) { p1Ref in
                        withUnsafePointer(to: &pt2) { p2Ref in
                            mfn(p1Ref, p2Ref, target, eventType, direction, 1.0, 1.0, size.width, size.height)
                        }
                    }
                }
            }
        case .touch: return nil
        }
    }
}
