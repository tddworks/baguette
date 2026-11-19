import Foundation

/// One connection to a running emulator's control API: opened with HTTP/2's
/// preface on its first call, each call on a stream of its own (odd, rising),
/// and a reader that hands a stream's messages on as they arrive and pays the
/// emulator back the window and settings acks it is owed.
///
/// A connection either sends (`send`: input, its replies unread) or streams
/// (`stream`: one call whose messages keep coming, the screen) — the screen and
/// the input each open their own, as Android Studio does.
final class EmulatorConnection: @unchecked Sendable {
    private let emulator: RunningEmulator
    private let openLink: @Sendable (Int) throws -> any EmulatorLink
    private let lock = NSLock()
    private var link: (any EmulatorLink)?
    private var nextStream: UInt32 = 1
    private var closed = false

    init(to emulator: RunningEmulator,
         openLink: @escaping @Sendable (Int) throws -> any EmulatorLink = { try TCPLink(port: $0) }) {
        self.emulator = emulator
        self.openLink = openLink
    }

    /// Call `method` with `message`, not waiting for its reply.
    func send(_ method: String, _ message: Data) throws {
        try call(method, message, reading: nil)
    }

    /// Call `method` with `message`; each message it streams back goes to
    /// `onMessage`, and `onEnd` runs if the emulator closes the link under
    /// it — never when this connection is closed.
    func stream(_ method: String, _ message: Data, onMessage: @escaping @Sendable (Data) -> Void,
                onEnd: @escaping @Sendable () -> Void = {}) throws {
        try call(method, message, reading: onMessage, onEnd: onEnd)
    }

    func close() {
        let link = lock.withLock {
            closed = true
            defer { self.link = nil }
            return self.link
        }
        link?.close()
    }

    private func call(_ method: String, _ message: Data, reading onMessage: (@Sendable (Data) -> Void)?,
                      onEnd: @escaping @Sendable () -> Void = {}) throws {
        let (link, stream, opened): (any EmulatorLink, UInt32, Bool)
        do {
            (link, stream, opened) = try place(method, message)
        } catch let failure as Failure {
            // The emulator closed the link (idle, restarted, an HTTP/2
            // error): once more on a fresh one, from stream 1 — leaving a
            // fresh one another call opened meanwhile alone.
            if let failed = failure.link { drop(failed) }
            do {
                (link, stream, opened) = try place(method, message)
            } catch let again as Failure {
                throw again.reason
            }
        }
        // One reader a connection, started with its first call: for a stream,
        // its messages; for sends, only what the emulator is owed.
        if opened || onMessage != nil {
            read(link, replies: GRPCReplies(stream: onMessage == nil ? 0 : stream), onMessage ?? { _ in }, onEnd: onEnd)
        }
    }

    /// Why a call couldn't be placed, and on which link, if one was open.
    struct Failure: Error {
        let link: (any EmulatorLink)?
        let reason: any Error
    }

    /// The connection was closed, or its emulator has no control API.
    struct Unreachable: Error {}

    /// Writes the call on this connection's link, opening one first if there
    /// is none — never once the connection is closed.
    private func place(_ method: String, _ message: Data) throws -> (any EmulatorLink, UInt32, Bool) {
        try lock.withLock {
            guard !closed, let control = emulator.control else { throw Unreachable() }
            let opened = self.link == nil
            let link: any EmulatorLink
            do { link = try self.link ?? openLink(control.port) } catch { throw Failure(link: nil, reason: error) }
            do {
                if opened {
                    self.link = link
                    nextStream = 1
                    try link.send(GRPCCall.opening)
                }
                let stream = nextStream
                nextStream += 2
                try link.send(GRPCCall(method: method, stream: stream, authority: "localhost:\(control.port)",
                                       token: control.token, message: message).bytes)
                return (link, stream, opened)
            } catch {
                throw Failure(link: link, reason: error)
            }
        }
    }

    /// Lets go of `failed` if it is still this connection's link, so the
    /// next call opens another.
    private func drop(_ failed: any EmulatorLink) {
        let current = lock.withLock { () -> Bool in
            guard self.link === failed else { return false }
            self.link = nil
            return true
        }
        if current { failed.close() }
    }

    private func read(_ link: any EmulatorLink, replies: GRPCReplies, _ onMessage: @escaping @Sendable (Data) -> Void,
                      onEnd: @escaping @Sendable () -> Void) {
        Thread.detachNewThread { [self] in
            var replies = replies
            // Until the connection closes or lets go of this link.
            while lock.withLock({ !closed && self.link === link }) {
                let bytes: Data?
                do {
                    bytes = try link.receive()
                } catch {
                    // The emulator closed its end: let the link go, and say
                    // so unless this connection was closed meanwhile.
                    let ended = lock.withLock { () -> Bool in
                        guard !closed, self.link === link else { return false }
                        self.link = nil
                        return true
                    }
                    link.close()
                    if ended { onEnd() }
                    return
                }
                guard let bytes else { continue }
                let messages = replies.push(bytes)
                let owed = replies.takeAnswers()
                if !owed.isEmpty { lock.withLock { try? link.send(owed) } }
                messages.forEach(onMessage)
            }
        }
    }
}
