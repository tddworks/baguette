import Foundation
import Darwin.Mach
import ObjectiveC

/// Production `Orientation` — drives the booted iOS guest's interface
/// orientation by sending a `GSEventTypeDeviceOrientationChanged`
/// mach message to the simulator's `PurpleWorkspacePort`.
///
/// Wire format and dispatch path are reverse-engineered from
/// `Simulator.app`'s `[SimDevice(GSEvents) gsEventsSendOrientation:]`
/// → `[SimDevice(GSEventsPrivate) sendPurpleEvent:]`, documented in
/// idb's `PrivateHeaders/SimulatorApp/GSEvent.h`. The 112-byte buffer
/// + port-patch logic lives in `OrientationEvent` (Domain, fully
/// unit-tested); this adapter is just the two irreducible system
/// calls the orchestrator can't make:
///
///   1. `simDevice.lookup("PurpleWorkspacePort", error:)` — translates
///      the bootstrap-namespace name to a live `mach_port_t`.
///   2. `mach_msg_send(header)`              — kernel hands the
///      patched buffer to GraphicsServices on the iOS side.
///
/// Both are integration-only.
final class PurpleEventOrientation: Orientation, @unchecked Sendable {
    private let udid: String
    private let host: any DeviceHost

    init(udid: String, host: any DeviceHost) {
        self.udid = udid
        self.host = host
    }

    func set(_ orientation: DeviceOrientation) -> Bool {
        guard let device = host.resolveDevice(udid: udid) else { return false }
        return OrientationEvent.send(
            orientation: orientation,
            lookupPort: { name in lookupMachPort(on: device, named: name) },
            deliver: { data in sendMachMessage(data) }
        )
    }
}

/// Resolve a `mach_port_t` from the simulator's bootstrap namespace by
/// name. Mirrors idb's `[simulator.device lookup:@"…" error:&err]`.
/// Returns `nil` when CoreSimulator hasn't vended that port (e.g.
/// device not booted yet) or the selector isn't present.
private func lookupMachPort(on device: NSObject, named name: String) -> UInt32? {
    let sel = NSSelectorFromString("lookup:error:")
    guard device.responds(to: sel) else { return nil }
    let imp = device.method(for: sel)
    typealias Lookup = @convention(c) (
        AnyObject, Selector, NSString, UnsafeMutablePointer<NSError?>?
    ) -> UInt32
    let fn = unsafeBitCast(imp, to: Lookup.self)
    var err: NSError?
    let port = fn(device, sel, name as NSString, &err)
    return port == 0 ? nil : port
}

/// Hand a fully-patched 112-byte `OrientationEvent` buffer to the
/// kernel. The buffer's `msgh_remote_port` (offset 0x08) MUST already
/// hold a live `PurpleWorkspacePort` — `OrientationEvent.send`
/// guarantees this when called via the orchestrator above.
private func sendMachMessage(_ data: Data) -> Bool {
    var copy = data
    let kr: kern_return_t = copy.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress else { return KERN_FAILURE }
        let header = base.assumingMemoryBound(to: mach_msg_header_t.self)
        return mach_msg_send(header)
    }
    return kr == KERN_SUCCESS
}
