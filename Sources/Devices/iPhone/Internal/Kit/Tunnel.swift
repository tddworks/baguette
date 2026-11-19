import Foundation
import Mockable

/// The phone's tunnel to this Mac, which CoreDevice keeps. Every service on
/// the phone — its live screen, its touchscreen — is reached through it, and
/// CoreDevice lets an idle one drop within seconds, so it is brought up
/// before anything is opened. Brought up, it stays until CoreDevice is told
/// to disconnect or the phone goes. The real one is `CoreDeviceTunnel`.
@Mockable
protocol Tunnel: Sendable {
    /// Bring `phone`'s tunnel up (CoreDevice's identifier, not the UDID);
    /// nothing to do when it already is. Blocks until CoreDevice answers.
    func open(to phone: UUID) throws
}
