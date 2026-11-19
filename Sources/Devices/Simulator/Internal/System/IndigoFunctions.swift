import BaguetteDevice
import Foundation

/// SimulatorKit's Indigo message builders, resolved once with `dlsym`. Any
/// one may be missing on an Xcode that lacks it.
struct IndigoFunctions {
    // IndigoHIDMessageForMouseNSEvent — 9-arg shape (Xcode 26 preview-kit).
    // Coords are NORMALIZED 0–1; target=0x32 routes to the touch digitizer.
    // direction: 1=down, 0=move, 2=up. nsEventType: 1=down, 2=up, 6=dragged.
    // (Its *real* ABI is 7 args — (p1, p2, target, eventType, edge,
    // NSSize.w, NSSize.h), `cmp x24, #0x4` bounds-checks the edge — but
    // the 9-arg shape is the one verified in production for taps, pans and
    // pinches. Do not change it: a wrong shape crashes backboardd.)
    typealias Mouse =
        @convention(c) (
            UnsafePointer<CGPoint>, UnsafePointer<CGPoint>?,
            UInt32, UInt32, UInt32,
            Double, Double,  // unused1, unused2 — pass 1.0
            Double, Double  // widthPoints, heightPoints
        ) -> UnsafeMutableRawPointer?
    typealias Button = @convention(c) (UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?
    /// (target, page, usage, operation) on iOS 26.
    typealias HIDArbitrary = @convention(c) (UInt32, UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?
    typealias Scroll = @convention(c) (UInt32, Double, Double, Double) -> UnsafeMutableRawPointer?
    typealias Service = @convention(c) () -> UnsafeMutableRawPointer?
    typealias CarPlayService = @convention(c) (UInt8) -> UnsafeMutableRawPointer?

    var mouse: Mouse?
    var button: Button?
    var hidArbitrary: HIDArbitrary?
    var scroll: Scroll?
    var createPointerService: Service?
    var createMouseService: Service?
    var removePointerService: Service?
    var createCarPlayService: CarPlayService?
    var removeCarPlayService: Service?

    /// `nil` when SimulatorKit cannot be found or opened.
    static func load() -> IndigoFunctions? {
        let dev = CoreSimulators.developerDir()
        guard let path = SimulatorKitFramework.path(developerDir: dev) else {
            logErr("SimulatorKit not found under \(dev) — see issue #28")
            return nil
        }
        guard let handle = dlopen(path, RTLD_NOW) else {
            logErr("SimulatorKit dlopen failed: \(dlerrorString())")
            return nil
        }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        let functions = IndigoFunctions(
            mouse: symbol("IndigoHIDMessageForMouseNSEvent", as: Mouse.self),
            button: symbol("IndigoHIDMessageForButton", as: Button.self),
            hidArbitrary: symbol("IndigoHIDMessageForHIDArbitrary", as: HIDArbitrary.self),
            scroll: symbol("IndigoHIDMessageForScrollEvent", as: Scroll.self),
            createPointerService: symbol("IndigoHIDMessageToCreatePointerService", as: Service.self),
            createMouseService: symbol("IndigoHIDMessageToCreateMouseService", as: Service.self),
            removePointerService: symbol("IndigoHIDMessageToRemovePointerService", as: Service.self),
            createCarPlayService: symbol("IndigoHIDMessageToCreateCarPlayService", as: CarPlayService.self),
            removeCarPlayService: symbol("IndigoHIDMessageToRemoveCarPlayService", as: Service.self))
        trace(
            "[hid] symbols resolved — mouse:\(functions.mouse != nil) button:\(functions.button != nil) "
                + "hidArb:\(functions.hidArbitrary != nil) scroll:\(functions.scroll != nil) "
                + "carPlaySvc:\(functions.createCarPlayService != nil)")
        return functions
    }
}
