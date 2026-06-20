import Foundation
import Mockable

/// Arms / disarms a simulator's launchd domain with
/// `DYLD_INSERT_LIBRARIES` pointing at the VirtualCamera dylib. The
/// env var survives until the simulator reboots, so the orchestrator
/// re-arms on boot rather than every time streaming starts.
@Mockable
protocol SimulatorInjection: AnyObject, Sendable {
    func arm(dylibPath: String, on simulator: any Simulator) async throws
    func disarm(on simulator: any Simulator) async throws
}
