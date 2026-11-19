import BaguetteDevice
import Foundation
import IOSurface

/// An emulator's screen, through its control API — as a simulator's: the
/// emulator draws each picture into memory baguette shares with it
/// (`SharedPicture`, a screen's worth, made at start) and sends only a notice
/// of its size; each is handed on from there as a BGRA surface. Nothing the
/// size of a picture crosses the socket. When the emulator ends the feed (it
/// closed the connection), the screen is still there: the feed starts again,
/// a second later, into the same memory, for as long as it's started.
final class EmulatorScreen: Screen, @unchecked Sendable {
    private let emulator: RunningEmulator
    private let screen: Size
    private let connect: @Sendable (RunningEmulator) -> EmulatorConnection
    private let share: @Sendable (Int) throws -> any SharedPicture
    private let pause: @Sendable (TimeInterval) -> Void
    private let lock = NSLock()
    private var connection: EmulatorConnection?
    private var shared: (any SharedPicture)?
    private var onFrame: (@Sendable (IOSurface) -> Void)?

    /// `screen` is in pixels; the memory holds one picture of it (a turned
    /// screen swaps its sides, never its size).
    init(emulator: RunningEmulator, screen: Size,
         connect: @escaping @Sendable (RunningEmulator) -> EmulatorConnection = { EmulatorConnection(to: $0) },
         share: @escaping @Sendable (Int) throws -> any SharedPicture = { try MappedSharedPicture(capacity: $0) },
         pause: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.emulator = emulator
        self.screen = screen
        self.connect = connect
        self.share = share
        self.pause = pause
    }

    func start(onFrame: @escaping @Sendable (IOSurface) -> Void) throws {
        let shared = try share(Int(screen.width * screen.height) * 4)
        lock.withLock { self.shared = shared; self.onFrame = onFrame }
        do { try open() } catch { stop(); throw error }
    }

    func stop() {
        let (connection, shared) = lock.withLock {
            onFrame = nil
            defer { self.connection = nil; self.shared = nil }
            return (self.connection, self.shared)
        }
        connection?.close()
        shared?.close()
    }

    private var started: Bool { lock.withLock { onFrame != nil } }

    private func open() throws {
        guard let (onFrame, shared) = lock.withLock({ () -> ((@Sendable (IOSurface) -> Void), any SharedPicture)? in
            guard let onFrame, let shared else { return nil }
            return (onFrame, shared)
        }) else { return }
        let connection = connect(emulator)
        lock.withLock { self.connection = connection }
        let format = EmulatorControl.ImageFormat(format: .rgba8888, sharedMemory: shared.handle)
        try connection.stream("streamScreenshot", format.bytes,
                              onMessage: { message in
                                  guard let notice = EmulatorControl.Image(message),
                                        let surface = EmulatorControl.Image.bgraSurface(
                                            width: notice.width, height: notice.height,
                                            pixels: UnsafeRawBufferPointer(start: shared.pixels, count: shared.capacity))
                                  else { return }
                                  onFrame(surface)
                              },
                              onEnd: { [weak self] in self?.reopen() })
    }

    /// Again, a second from now, while started; again after that if it fails.
    private func reopen() {
        pause(1)
        guard started else { return }
        do { try open() } catch { reopen() }
    }
}
