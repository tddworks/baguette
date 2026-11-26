import Foundation

/// What this process can reach of Xcode's CoreDevice, for a phone on a cable:
/// whether it answers, a phone's tunnel, its touch service and its live
/// screen. The iPhone family never links CoreDevice itself — it is
/// weak-linked with linker flags SwiftPM refuses from a version-pinned
/// dependency — so a host hands it over: the `baguette` CLI and any host that
/// adds the `BaguetteCoreDevice` product pass `.live`. Everyone else gets
/// `.absent`: a phone's screen as devicectl stills, and no touch.
public struct CoreDeviceAccess: Sendable {
    package let isAvailable: @Sendable () -> Bool
    package let connect: @Sendable (UUID) throws -> Void
    package let universalHID: any UniversalHID
    package let mediaStream: any MediaStreamStarter

    package init(
        isAvailable: @escaping @Sendable () -> Bool,
        connect: @escaping @Sendable (UUID) throws -> Void,
        universalHID: any UniversalHID,
        mediaStream: any MediaStreamStarter
    ) {
        self.isAvailable = isAvailable
        self.connect = connect
        self.universalHID = universalHID
        self.mediaStream = mediaStream
    }

    /// No CoreDevice: what a Mac without it has always had.
    public static let absent = CoreDeviceAccess(
        isAvailable: { false },
        connect: { _ in throw CoreDeviceError.unavailable },
        universalHID: NoUniversalHID(),
        mediaStream: NoMediaStream()
    )
}

/// The touch service of a process without CoreDevice: it builds no reports
/// and opens nothing.
private struct NoUniversalHID: UniversalHID {
    var buildsTouchReports: Bool { false }
    func open(on phone: UUID) throws -> OpenedCapability? { nil }
    func send(_ report: DigitizerReport, to service: UInt32, through capability: OpenedCapability) -> Bool { false }
}

/// The live screen of a process without CoreDevice: never listed.
private struct NoMediaStream: MediaStreamStarter {
    func start(on phone: UUID, request: @escaping @Sendable () throws -> [String: Any]) throws -> [String: Any] {
        throw MediaStreamError.notListed
    }
}
