import Foundation
import IOSurface
import ObjectiveC

/// Production `Screen` — registers SimulatorKit framebuffer callbacks via
/// the ObjC runtime and forwards `IOSurface` frames to the caller as they
/// arrive. Pure pass-through: emits exactly when SimulatorKit composites
/// a new frame and nothing more. Cadence policy (5 fps for MJPEG,
/// 60 fps for H.264, etc.) belongs in the consumer — see `StreamSession`.
///
/// Multi-descriptor: simulators expose secondary planes / overlays. We
/// register on every `com.apple.framebuffer.display` descriptor and pick
/// a surface each tick — largest area by default, or the plane closest
/// to an optional `DisplayBinding` size when one is supplied.
final class SimulatorKitScreen: Screen, @unchecked Sendable {
    private let udid: String
    private let host: any DeviceHost
    private let binding: DisplayBinding?
    private let queue = DispatchQueue(label: "baguette.screen", qos: .userInteractive)

    private var ioClient: NSObject?
    private var descriptors: [NSObject] = []
    private var callbackUUIDs: [ObjectIdentifier: NSUUID] = [:]
    private var onFrame: (@Sendable (IOSurface) -> Void)?
    private var idleTimer: DispatchSourceTimer?
    /// Guards against queueing duplicate captures — see `scheduleCapture`.
    /// Only ever touched on `queue`, which is serial.
    private var pending = PendingCapture()

    init(udid: String, host: any DeviceHost, binding: DisplayBinding? = nil) {
        self.udid = udid
        self.host = host
        self.binding = binding
    }

    private func resolveDevice() -> NSObject? {
        host.resolveDevice(udid: udid)
    }

    func start(onFrame: @escaping @Sendable (IOSurface) -> Void) throws {
        self.onFrame = onFrame

        guard let device = resolveDevice() else {
            throw SimulatorError.notFound(udid: udid)
        }
        guard let io = device.perform(NSSelectorFromString("io"))?
            .takeUnretainedValue() as? NSObject
        else {
            throw ScreenError.ioUnavailable
        }
        self.ioClient = io
        try wireFramebuffer()
        startIdleFloorIfNeeded()
    }

    func stop() {
        idleTimer?.cancel()
        idleTimer = nil
        let unregSel = NSSelectorFromString("unregisterScreenCallbacksWithUUID:")
        for desc in descriptors {
            if let uuid = callbackUUIDs[ObjectIdentifier(desc)],
               desc.responds(to: unregSel) {
                desc.perform(unregSel, with: uuid)
            }
        }
        descriptors.removeAll()
        callbackUUIDs.removeAll()
        ioClient = nil
        onFrame = nil
    }

    // MARK: - private

    private func startIdleFloorIfNeeded() {
        let kind = binding?.kind ?? .phone
        guard ScreenIdleFloor.isEnabled(for: kind) else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(),
            repeating: .nanoseconds(Int(ScreenIdleFloor.intervalNanoseconds))
        )
        timer.setEventHandler { [weak self] in
            self?.scheduleCapture()
        }
        timer.resume()
        idleTimer = timer
    }

    private func wireFramebuffer() throws {
        guard let io = ioClient else { throw ScreenError.ioUnavailable }

        var         candidates = findFramebufferDescriptors(io: io)
        if IOPortsRefresh.shouldUpdate(hasFramebufferDisplayPorts: !candidates.isEmpty) {
            io.perform(NSSelectorFromString("updateIOPorts"))
            candidates = findFramebufferDescriptors(io: io)
        }
        guard !candidates.isEmpty else { throw ScreenError.noFramebuffer }
        descriptors = candidates

        for desc in candidates {
            try registerCallbacks(on: desc)
        }
        // Surfaces often populate only after callbacks are registered —
        // pull once now and let the idle floor keep pulling.
        queue.async { [weak self] in self?.scheduleCapture() }
    }

    private func findFramebufferDescriptors(io: NSObject) -> [NSObject] {
        guard let ports = io.value(forKey: "deviceIOPorts") as? [NSObject] else {
            return []
        }

        let pidSel = NSSelectorFromString("portIdentifier")
        let descSel = NSSelectorFromString("descriptor")
        let surfSel = NSSelectorFromString("framebufferSurface")

        var candidates: [NSObject] = []
        for port in ports where port.responds(to: pidSel) {
            guard let pid = port.perform(pidSel)?.takeUnretainedValue(),
                  "\(pid)" == "com.apple.framebuffer.display",
                  port.responds(to: descSel),
                  let desc = port.perform(descSel)?.takeUnretainedValue() as? NSObject,
                  desc.responds(to: surfSel)
            else { continue }
            candidates.append(desc)
        }
        return candidates
    }

    private func registerCallbacks(on desc: NSObject) throws {
        let regSel = NSSelectorFromString(
            "registerScreenCallbacksWithUUID:callbackQueue:frameCallback:" +
                "surfacesChangedCallback:propertiesChangedCallback:"
        )
        guard desc.responds(to: regSel) else { throw ScreenError.callbackUnavailable }

        let uuid = NSUUID()
        callbackUUIDs[ObjectIdentifier(desc)] = uuid

        let frame: @convention(block) () -> Void = { [weak self] in
            self?.scheduleCapture()
        }
        let surfaces: @convention(block) () -> Void = { [weak self] in
            self?.scheduleCapture()
        }
        let props: @convention(block) () -> Void = {}

        guard let imp = class_getMethodImplementation(type(of: desc), regSel) else {
            throw ScreenError.callbackUnavailable
        }
        typealias Fn = @convention(c) (
            AnyObject, Selector, AnyObject, AnyObject, AnyObject, AnyObject, AnyObject
        ) -> Void
        unsafeBitCast(imp, to: Fn.self)(
            desc, regSel,
            uuid, queue as AnyObject,
            frame as AnyObject, surfaces as AnyObject, props as AnyObject
        )
    }

    /// Queue a capture unless one is already waiting to run.
    ///
    /// Registered callbacks are delivered on `queue`, so this is serial with
    /// the capture itself. Without the coalescer, a composite rate above the
    /// capture rate enqueues duplicates without bound — each one paying a
    /// synchronous XPC round-trip for `framebufferSurface` and its share of
    /// autorelease churn — and the process runs away rather than degrading.
    private func scheduleCapture() {
        guard pending.request() else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.pending.begin()
            self.captureLatest()
        }
    }

    /// Picks the descriptor for this screen's plane and forwards its
    /// IOSurface to `onFrame`. CarPlay bindings never fall back to the
    /// phone plane — missing external surfaces emit nothing.
    /// Drains its own autorelease pool.
    ///
    /// `framebufferSurface` forwards through ROCKit to CoreSimulatorService,
    /// and that round-trip leaves XPC replies, dispatch groups and the
    /// IOSurface itself autoreleased. At frame rate, across several streams,
    /// those temporaries are the bulk of the process's allocation — so the
    /// pool is drained per capture rather than left to whatever pool the
    /// enclosing work item happens to provide.
    ///
    /// The body is a separate method on purpose: `return` inside an
    /// `autoreleasepool { }` closure returns from the *closure*, so inlining
    /// the guards below would quietly change their control flow.
    private func captureLatest() {
        autoreleasepool { performCapture() }
    }

    private func performCapture() {
        let surfSel = NSSelectorFromString("framebufferSurface")
        var surfaces: [(IOSurface, Size)] = []
        for desc in descriptors {
            guard let surfObj = desc.perform(surfSel)?.takeUnretainedValue() else { continue }
            let surf = unsafeBitCast(surfObj, to: IOSurface.self)
            let w = IOSurfaceGetWidth(surf)
            let h = IOSurfaceGetHeight(surf)
            guard w > 0, h > 0 else { continue }
            surfaces.append((surf, Size(width: Double(w), height: Double(h))))
        }
        guard let index = FramebufferSurfacePick.index(
            binding: binding,
            candidates: surfaces.map(\.1)
        ) else { return }
        onFrame?(surfaces[index].0)
    }
}

enum ScreenError: Error, Equatable {
    case ioUnavailable
    case noFramebuffer
    case callbackUnavailable
}
