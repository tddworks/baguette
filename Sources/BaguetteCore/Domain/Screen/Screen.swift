import Foundation
import IOSurface
import Mockable

/// The simulator's screen — a stream of GPU framebuffer surfaces. Two
/// verbs: `start` to subscribe, `stop` to tear down. Per simulator.
///
/// `IOSurface` is a public Apple type (zero-copy framebuffer), not
/// private API, so it's safe to expose at the domain boundary.
@Mockable
protocol Screen: AnyObject, Sendable {
    /// Subscribe to frame delivery. Throws if SimulatorKit's screen pipe
    /// can't be wired (e.g. simulator isn't booted). The closure runs on
    /// the screen's own dispatch queue.
    func start(onFrame: @escaping @Sendable (IOSurface) -> Void) throws

    /// Tear down callbacks and release the underlying screen object.
    func stop()
}
