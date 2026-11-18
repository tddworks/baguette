import Foundation
import IOSurface

/// A physical phone's screen, as `devicectl device capture screenshot`
/// takes it: one PNG per call, decoded to a surface and handed on, then
/// the next. Roughly one frame a second over USB — a picture of the
/// phone, not a live stream (that waits on CoreDevice's display service,
/// see docs/features/real-devices/design.md).
final class DevicectlScreen: Screen, @unchecked Sendable {
    private let udid: String
    private let devicectl: Devicectl
    private let decode: @Sendable (URL) -> IOSurface?
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "baguette.devicectl-screen")
    private let lock = NSLock()
    private var running = false
    private let file: URL

    init(
        udid: String,
        devicectl: Devicectl,
        decode: @escaping @Sendable (URL) -> IOSurface? = { ImageSurface.load($0) },
        interval: TimeInterval = 0.2
    ) {
        self.udid = udid
        self.devicectl = devicectl
        self.decode = decode
        self.interval = interval
        self.file = FileManager.default.temporaryDirectory
            .appendingPathComponent("baguette-\(udid)-\(UUID().uuidString).png")
    }

    func start(onFrame: @escaping @Sendable (IOSurface) -> Void) throws {
        lock.withLock { running = true }
        queue.async { self.shoot(onFrame) }
    }

    func stop() {
        lock.withLock { running = false }
    }

    private var isRunning: Bool { lock.withLock { running } }

    private func shoot(_ onFrame: @escaping @Sendable (IOSurface) -> Void) {
        guard isRunning else { return }
        let taken = (try? devicectl.runAndWait([
            "device", "capture", "screenshot", "--device", udid, "--destination", file.path,
        ])) != nil
        if taken, isRunning, let surface = decode(file) { onFrame(surface) }
        try? FileManager.default.removeItem(at: file)
        guard isRunning else { return }
        queue.asyncAfter(deadline: .now() + interval) { self.shoot(onFrame) }
    }
}
