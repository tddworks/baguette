import BaguetteDevice
import Foundation

/// Events told to the Mac's window server: each posted in order, pauses
/// kept. Refuses — posts nothing — while this process isn't trusted for
/// Accessibility, asking once; once trusted it isn't asked again (a pointer
/// move costs ~0.2 ms, not the ~1.4 ms of asking each time).
final class WindowServerEvents: HostEvents, @unchecked Sendable {
    private let server: any WindowServer
    private let pause: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var isTrusted = false
    private var asked = false

    init(server: any WindowServer,
         pause: @escaping @Sendable (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.server = server
        self.pause = pause
    }

    func post(_ events: [HostEvent]) -> Bool {
        guard trusted() else { return false }
        for event in events {
            if case let .pause(seconds) = event {
                if seconds > 0 { pause(seconds) }
            } else {
                server.post(event)
            }
        }
        return true
    }

    private func trusted() -> Bool {
        if lock.withLock({ isTrusted }) { return true }
        let ask = lock.withLock { defer { asked = true }; return !asked }
        guard server.trusted(asking: ask) else {
            log("[mac] input refused: allow the app that runs baguette in System Settings › Privacy & Security › Accessibility")
            return false
        }
        lock.withLock { isTrusted = true }
        return true
    }
}
