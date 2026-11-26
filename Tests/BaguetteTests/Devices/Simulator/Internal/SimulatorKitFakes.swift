@testable import BaguetteDeviceFamilies
import CoreVideo
import Foundation
import IOSurface

/// Stand-ins for the SimulatorKit objects a `SimDevice` hands out, each
/// answering only the selectors baguette sends: a device's `io` client,
/// its `deviceIOPorts`, a port's `portIdentifier` / `descriptor`, and a
/// descriptor's `framebufferSurface` and screen callbacks.
final class FakeKitDevice: NSObject, @unchecked Sendable {
    private let client: NSObject?
    init(io: NSObject?) { client = io }
    @objc func io() -> NSObject? { client }
}

final class FakeKitIO: NSObject, @unchecked Sendable {
    @objc var deviceIOPorts: [NSObject]
    /// What `updateIOPorts` materialises, when it materialises anything.
    private let afterUpdate: [NSObject]?
    private(set) var updates = 0

    init(ports: [NSObject], afterUpdate: [NSObject]? = nil) {
        deviceIOPorts = ports
        self.afterUpdate = afterUpdate
    }

    @objc func updateIOPorts() {
        updates += 1
        if let afterUpdate { deviceIOPorts = afterUpdate }
    }
}

/// A port with an identifier and, optionally, a descriptor.
final class FakeKitPort: NSObject, @unchecked Sendable {
    private let identifier: String
    private let desc: NSObject?
    init(_ identifier: String = "com.apple.framebuffer.display", descriptor: NSObject?) {
        self.identifier = identifier
        desc = descriptor
    }
    @objc func portIdentifier() -> NSString { identifier as NSString }
    @objc func descriptor() -> NSObject? { desc }
}

/// A display port that knows its default size, as one does before its
/// first surface is composited.
final class FakeKitSizedPort: NSObject, @unchecked Sendable {
    private let desc: NSObject?
    @objc let defaultWidth: NSNumber
    @objc let defaultHeight: NSNumber
    init(width: Double, height: Double, descriptor: NSObject?) {
        defaultWidth = NSNumber(value: width)
        defaultHeight = NSNumber(value: height)
        desc = descriptor
    }
    @objc func portIdentifier() -> NSString { "com.apple.framebuffer.display" }
    @objc func descriptor() -> NSObject? { desc }
}

/// A port with an identifier but no descriptor selector at all.
final class FakeKitBarePort: NSObject {
    @objc func portIdentifier() -> NSString { "com.apple.framebuffer.display" }
}

/// A framebuffer descriptor: its current surface, and the screen
/// callbacks SimulatorKit would call as it composites.
final class FakeKitDescriptor: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var current: IOSurface?
    private var callbacks: [(uuid: NSUUID, frame: () -> Void, surfaces: () -> Void)] = []
    private(set) var unregistered: [NSUUID] = []

    init(surface: IOSurface?) { current = surface }

    var surface: IOSurface? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    var registered: [NSUUID] { lock.withLock { callbacks.map(\.uuid) } }

    @objc func framebufferSurface() -> IOSurface? { surface }

    @objc(registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:)
    func register(
        uuid: NSUUID, queue: AnyObject,
        frame: @escaping @convention(block) () -> Void,
        surfaces: @escaping @convention(block) () -> Void,
        properties: @escaping @convention(block) () -> Void
    ) {
        lock.withLock { callbacks.append((uuid, frame, surfaces)) }
    }

    @objc(unregisterScreenCallbacksWithUUID:) func unregister(_ uuid: NSUUID) {
        lock.withLock { unregistered.append(uuid) }
    }

    /// SimulatorKit composited a new frame.
    func composite() { lock.withLock { callbacks }.forEach { $0.frame() } }

    /// SimulatorKit swapped the descriptor's surfaces.
    func swapSurfaces() { lock.withLock { callbacks }.forEach { $0.surfaces() } }
}

/// A descriptor that has a surface but takes no screen callbacks.
final class FakeKitSilentDescriptor: NSObject {
    private let surface: IOSurface?
    init(surface: IOSurface?) { self.surface = surface }
    @objc func framebufferSurface() -> IOSurface? { surface }
}

enum FakeKit {
    /// A real surface of this many pixels.
    static func surface(_ width: Int, _ height: Int) -> IOSurface {
        IOSurface(properties: [
            .width: width, .height: height, .bytesPerElement: 4,
            .pixelFormat: kCVPixelFormatType_32BGRA,
        ])!
    }

    /// A device whose display framebuffers are already composited at these sizes.
    static func device(_ sizes: [(Int, Int)]) -> (FakeKitDevice, [FakeKitDescriptor]) {
        let descriptors = sizes.map { FakeKitDescriptor(surface: surface($0.0, $0.1)) }
        let io = FakeKitIO(ports: descriptors.map { FakeKitPort(descriptor: $0) })
        return (FakeKitDevice(io: io), descriptors)
    }
}
