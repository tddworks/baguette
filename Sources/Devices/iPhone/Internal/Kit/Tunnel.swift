import Foundation
import Mockable

/// The phone's tunnel to this Mac, which CoreDevice keeps. Every service on
/// the phone — its live screen, its touchscreen, its accessibility — is
/// reached through it, and CoreDevice lets an idle one drop within seconds,
/// so it is brought up before anything is opened. Brought up, it stays
/// until CoreDevice is told to disconnect or the phone goes. The one owner
/// of bringing it up and of where it is; the real one is `CoreDeviceTunnel`.
@Mockable
protocol Tunnel: Sendable {
    /// Bring `phone`'s tunnel up (CoreDevice's identifier, not the UDID),
    /// and say where its two ends are. Blocks until CoreDevice answers.
    func open(to phone: UUID) throws -> TunnelEnds
}

/// Where a phone's tunnel ends: the phone at `…::1`, this Mac at its own
/// address on the same prefix (`…::2`).
struct TunnelEnds: Equatable, Sendable {
    let phone: String
    let mac: String
}

enum TunnelError: Error, Equatable, CustomStringConvertible {
    /// CoreDevice connected the phone, yet lists no tunnel to it.
    case down
    /// The tunnel is up, but this Mac has no address on it.
    case noMacEnd

    var description: String {
        switch self {
        case .down: "the phone's CoreDevice tunnel isn't up"
        case .noMacEnd: "this Mac has no address on the phone's CoreDevice tunnel"
        }
    }
}
