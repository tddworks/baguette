import Foundation
import Mockable

/// The bytes to and from one emulator's control API — a TCP connection to
/// its gRPC port on loopback. Decides nothing: what is written and what the
/// replies mean is `EmulatorConnection`'s. The real one is `TCPLink`.
@Mockable
protocol EmulatorLink: AnyObject, Sendable {
    func send(_ bytes: Data) throws
    /// What arrived next, or nil when nothing did within a short wait.
    /// Throws once the emulator has closed its end.
    func receive() throws -> Data?
    func close()
}
