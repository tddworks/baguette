import Foundation

/// The shared camera frame buffer admits one owner for the whole server.
/// Failed cleanup retains ownership unless the guest is confirmed terminated.
@MainActor
final class CameraSessions {
    private struct Owner {
        let udid: String
        let session: CameraSession
        var connected: Bool
    }

    private var owner: Owner?
    let guestTerminated: @Sendable (String) throws -> Bool

    nonisolated init(guestTerminated: @escaping @Sendable (String) throws -> Bool) {
        self.guestTerminated = guestTerminated
    }

    func connect(udid: String, makeSession: () throws -> CameraSession) throws -> CameraSession {
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

    func disconnect(_ session: CameraSession) async {
        guard owner?.session === session else { return }
        // An explicit failed stop must not be retried merely by closing its socket.
        if !session.cleanupRequired { await session.stop() }
        if session.cleanupRequired {
            owner?.connected = false
        } else {
            owner = nil
        }
    }
}

struct CameraOwnershipError: LocalizedError {
    let udid: String
    var errorDescription: String? {
        "Camera is owned by \(udid). Close its camera connection or reconnect to that device to finish cleanup."
    }
}
