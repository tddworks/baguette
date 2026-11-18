import BaguetteDevice
import Darwin
import Foundation

/// This Mac's SimulatorKit and IOKit, for the trackpad probe: the dlsym +
/// IOHIDEvent dance that builds an Indigo message from a digitizer finger.
struct HostIndigoMessages: IndigoMessages {
    static let pause: @Sendable (UInt32) -> Void = { usleep($0 * 1000) }

    /// `RTLD_DEFAULT`: IOHIDEvent lives in the dyld shared cache.
    private static var shared: UnsafeMutableRawPointer? { UnsafeMutableRawPointer(bitPattern: -2) }

    func trackpad(from finger: DigitizerFinger) -> TrackpadMessage {
        let dev = CoreSimulators.developerDir()
        guard let kitPath = SimulatorKitFramework.path(developerDir: dev) else {
            return .refused("SimulatorKit not found under \(dev) — see issue #28")
        }
        guard let kit = dlopen(kitPath, RTLD_NOW) else {
            return .refused("dlopen SimulatorKit failed: \(String(cString: dlerror()))")
        }
        guard let wrapSym = dlsym(kit, "IndigoHIDMessageForTrackpadEventFromHIDEventRef") else {
            return .refused("IndigoHIDMessageForTrackpadEventFromHIDEventRef unresolved")
        }
        typealias WrapFn = @convention(c) (UnsafeRawPointer) -> UnsafeMutableRawPointer?
        guard let createSym = dlsym(Self.shared, "IOHIDEventCreateDigitizerFingerEvent") else {
            return .refused("IOHIDEventCreateDigitizerFingerEvent unresolved")
        }
        // (allocator, time, index, identifier, mask, x, y, z, pressure, twist, range, touch, options)
        typealias CreateFn = @convention(c) (
            CFAllocator?, UInt64, UInt32, UInt32, UInt32,
            Double, Double, Double, Double, Double, Bool, Bool, UInt32
        ) -> Unmanaged<CFTypeRef>?
        guard let fingerEvent = unsafeBitCast(createSym, to: CreateFn.self)(
            nil, mach_absolute_time(), finger.index, finger.identifier, finger.eventMask,
            finger.x, finger.y, 0.0, finger.pressure, 0.0, finger.range, finger.touch, 0
        )?.takeRetainedValue() else {
            return .refused("IOHIDEventCreateDigitizerFingerEvent returned nil")
        }
        let event: CFTypeRef
        switch parent(of: fingerEvent, as: finger) {
        case .success(let parent): event = parent
        case .failure(let refusal): return .refused(refusal.reason)
        }
        let raw = Unmanaged.passUnretained(event as AnyObject).toOpaque()
        guard let msg = unsafeBitCast(wrapSym, to: WrapFn.self)(raw) else {
            return .refused("IndigoHIDMessageForTrackpadEventFromHIDEventRef returned nil")
        }
        defer { free(msg) }
        let size = malloc_size(msg)
        return .built(Array(UnsafeBufferPointer(start: msg.assumingMemoryBound(to: UInt8.self), count: size)))
    }

    private struct Refusal: Error { let reason: String }

    /// `finger` itself — or, `withParent`, a digitizer parent (transducer
    /// Finger) with `finger` appended as its child, as real touches arrive.
    private func parent(of event: CFTypeRef, as finger: DigitizerFinger) -> Result<CFTypeRef, Refusal> {
        guard finger.withParent else { return .success(event) }
        guard let createSym = dlsym(Self.shared, "IOHIDEventCreateDigitizerEvent") else {
            return .failure(Refusal(reason: "IOHIDEventCreateDigitizerEvent unresolved"))
        }
        // (allocator, time, transducer, index, identifier, mask, buttons,
        //  x, y, z, tipPressure, barrelPressure, range, touch, options)
        typealias CreateParentFn = @convention(c) (
            CFAllocator?, UInt64, UInt32, UInt32, UInt32, UInt32, UInt32,
            Double, Double, Double, Double, Double, Bool, Bool, UInt32
        ) -> Unmanaged<CFTypeRef>?
        guard let parent = unsafeBitCast(createSym, to: CreateParentFn.self)(
            nil, mach_absolute_time(), 2, finger.index, finger.identifier, finger.eventMask, 0,
            finger.x, finger.y, 0.0, finger.pressure, 0.0, finger.range, finger.touch, 0
        )?.takeRetainedValue() else {
            return .failure(Refusal(reason: "IOHIDEventCreateDigitizerEvent returned nil"))
        }
        guard let appendSym = dlsym(Self.shared, "IOHIDEventAppendEvent") else {
            return .failure(Refusal(reason: "IOHIDEventAppendEvent unresolved"))
        }
        typealias AppendFn = @convention(c) (CFTypeRef, CFTypeRef, UInt32) -> Void
        unsafeBitCast(appendSym, to: AppendFn.self)(parent, event, 0)
        return .success(parent)
    }
}
