import BaguetteDevice
import Foundation
import IOSurface

/// An emulator's screen, through its control API: one `streamScreenshot`
/// call on a connection of its own, the emulator pushing an RGBA picture
/// each time the screen changes, each handed on as a BGRA surface.
final class EmulatorScreen: Screen, @unchecked Sendable {
    private let emulator: RunningEmulator
    private let connect: @Sendable (RunningEmulator) -> EmulatorConnection
    private let lock = NSLock()
    private var connection: EmulatorConnection?

    init(emulator: RunningEmulator,
         connect: @escaping @Sendable (RunningEmulator) -> EmulatorConnection = { EmulatorConnection(to: $0) }) {
        self.emulator = emulator
        self.connect = connect
    }

    func start(onFrame: @escaping @Sendable (IOSurface) -> Void) throws {
        let connection = connect(emulator)
        lock.withLock { self.connection = connection }
        try connection.stream("streamScreenshot", EmulatorControl.ImageFormat(format: .rgba8888).bytes) { message in
            guard let surface = EmulatorControl.Image(message)?.bgraSurface() else { return }
            onFrame(surface)
        }
    }

    func stop() {
        let connection = lock.withLock { defer { self.connection = nil }; return self.connection }
        connection?.close()
    }
}
