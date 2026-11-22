import BaguetteDevice
import Foundation

/// Each display in a process of its own — `baguette virtual-display`. Measured
/// on macOS 27: a process can choose the mode of only the first virtual display
/// it makes, and a display goes when its process does, so each display is the
/// first of its own process, and removing it is ending that process. A crash
/// in the private API ends only that process. Design: docs/features/mac-screen/design.md.
final class ChildVirtualDisplays: VirtualDisplays, @unchecked Sendable {
    private let executable: URL
    private let makeProcess: @Sendable () -> any Subprocess
    private let wait: TimeInterval
    private let isListed: @Sendable (UInt32) -> Bool

    /// `wait`: how long a process has to announce its display. `isListed`:
    /// whether the Mac still lists a display, so removing one finishes when
    /// it is gone — macOS chooses a new main display only then.
    init(executable: URL, makeProcess: @escaping @Sendable () -> any Subprocess, wait: TimeInterval = 5,
         isListed: @escaping @Sendable (UInt32) -> Bool = HostDisplayList.isListed) {
        self.executable = executable
        self.makeProcess = makeProcess
        self.wait = wait
        self.isListed = isListed
    }

    func create(named name: String, shape: SharedScreenShape, serial: UInt32) -> (any VirtualDisplay)? {
        let process = makeProcess()
        let heard = Heard()
        do {
            try process.run(
                executable: executable,
                arguments: ["virtual-display", "--name", name,
                            "--width", String(Int(shape.points.width)), "--height", String(Int(shape.points.height)),
                            "--serial", String(serial)],
                onBytes: { heard.hear($0) },
                onExit: { _ in heard.ended() })
        } catch {
            return nil
        }
        guard case let .ready(id, uuid) = heard.announcement(within: wait) else {
            process.terminate()
            return nil
        }
        return ChildDisplay(id: id, uuid: uuid, process: process, isListed: isListed)
    }

    /// What a process has said, until it announces itself or ends.
    private final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)
        private var lines = LineBuffer()
        private var said: VirtualDisplayAnnouncement?
        private var over = false

        func hear(_ bytes: Data) {
            let announced = lock.withLock { () -> Bool in
                guard !over else { return false }
                said = lines.append(bytes).lazy.compactMap(VirtualDisplayAnnouncement.init(line:)).first
                over = said != nil
                return over
            }
            if announced { done.signal() }
        }

        func ended() {
            let first = lock.withLock { defer { over = true }; return !over }
            if first { done.signal() }
        }

        func announcement(within seconds: TimeInterval) -> VirtualDisplayAnnouncement? {
            _ = done.wait(timeout: .now() + seconds)
            return lock.withLock { said }
        }
    }

    private final class ChildDisplay: VirtualDisplay, @unchecked Sendable {
        let id: UInt32
        let uuid: String
        private let process: any Subprocess
        private let isListed: @Sendable (UInt32) -> Bool

        init(id: UInt32, uuid: String, process: any Subprocess, isListed: @escaping @Sendable (UInt32) -> Bool) {
            self.id = id
            self.uuid = uuid
            self.process = process
            self.isListed = isListed
        }

        /// End its process; return once the Mac lists the display no more — 2 s at most.
        func remove() {
            process.terminate()
            var looks = 0
            while looks < 40, isListed(id) {
                looks += 1
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }
}
