import Foundation

/// The shared camera frame buffer admits one owner for the whole server.
/// Failed cleanup retains ownership unless the guest is confirmed terminated.
@MainActor
public final class CameraSessions {
    private struct Owner {
        let udid: String
        let session: CameraSession
        var connected: Bool
    }

    private var owner: Owner?
    /// The disconnect still running for the current owner. A socket that
    /// reconnects while the previous one is tearing down waits for that
    /// outcome instead of being refused as a second live connection.
    private var teardown: Task<Void, Never>?
    public let guestTerminated: @Sendable (String) throws -> Bool

    public nonisolated init(guestTerminated: @escaping @Sendable (String) throws -> Bool) {
        self.guestTerminated = guestTerminated
    }

    public func connect(udid: String, makeSession: () throws -> CameraSession) async throws -> CameraSession {
        await teardown?.value
        if var existing = owner {
            guard !existing.connected else {
                throw CameraOwnershipError(udid: existing.udid)
            }
            if existing.udid == udid {
                existing.connected = true
                owner = existing
                return existing.session
            }
            guard try guestTerminated(existing.udid) else {
                throw CameraOwnershipError(udid: existing.udid)
            }
            owner = nil
        }
        let session = try makeSession()
        owner = Owner(udid: udid, session: session, connected: true)
        return session
    }

    public func disconnect(_ session: CameraSession) async {
        guard owner?.session === session else { return }
        let task = Task { [self] in
            // An explicit failed stop must not be retried merely by closing its socket.
            if !session.cleanupRequired { await session.stop() }
            if session.cleanupRequired {
                owner?.connected = false
            } else {
                owner = nil
            }
        }
        teardown = task
        await task.value
        if teardown == task { teardown = nil }
    }
}

public struct CameraOwnershipError: LocalizedError {
    public let udid: String
    public var errorDescription: String? {
        "Camera is owned by \(udid). Close its camera connection or reconnect to that device to finish cleanup."
    }

    public init(udid: String) {
        self.udid = udid
    }
}
