import BaguetteDevice
import Foundation

/// This Mac's display arrangement, read here but changed only by a short
/// process of its own — `baguette main-display`. Measured on macOS 27: once a
/// process changes the arrangement, displays added later never appear in its
/// own display list, though every other process sees them within half a
/// second; the server has to keep seeing them, to list and stream them.
/// Design: docs/features/mac-screen/design.md.
final class ChildDisplayArrangement: DisplayArrangement, @unchecked Sendable {
    private let executable: URL
    private let makeProcess: @Sendable () -> any Subprocess
    private let readMain: @Sendable () -> UInt32
    private let wait: TimeInterval

    /// `wait`: how long the process has to finish.
    init(executable: URL, makeProcess: @escaping @Sendable () -> any Subprocess,
         readMain: @escaping @Sendable () -> UInt32 = HostDisplayList.main, wait: TimeInterval = 5) {
        self.executable = executable
        self.makeProcess = makeProcess
        self.readMain = readMain
        self.wait = wait
    }

    var main: UInt32 { readMain() }

    func makeMain(_ display: UInt32, freeingDock: Bool) -> Bool {
        let process = makeProcess()
        let finished = DispatchSemaphore(value: 0)
        let status = Status()
        do {
            try process.run(executable: executable, arguments: ["main-display", "--display", String(display)] + (freeingDock ? ["--free-dock"] : []),
                            onBytes: { _ in }, onExit: { status.set($0); finished.signal() })
        } catch {
            return false
        }
        guard finished.wait(timeout: .now() + wait) == .success else {
            process.terminate()
            return false
        }
        return status.value == 0
    }

    private final class Status: @unchecked Sendable {
        private let lock = NSLock()
        private var code: Int32?
        var value: Int32? { lock.withLock { code } }
        func set(_ code: Int32) { lock.withLock { self.code = code } }
    }
}
