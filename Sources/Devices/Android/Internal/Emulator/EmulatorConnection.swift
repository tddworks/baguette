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

    /// Call `method` with `message`; each message it streams back goes to `onMessage`.
    func stream(_ method: String, _ message: Data, onMessage: @escaping @Sendable (Data) -> Void) throws {
        try call(method, message, reading: onMessage)
    }

    func close() {
        let link = lock.withLock {
            closed = true
            defer { self.link = nil }
            return self.link
        }
        link?.close()
    }

    private func call(_ method: String, _ message: Data, reading onMessage: (@Sendable (Data) -> Void)?) throws {
        let (link, stream, opened): (any EmulatorLink, UInt32, Bool)
        do {
            (link, stream, opened) = try place(method, message)
        } catch {
            // The emulator closed the link (idle, restarted, an HTTP/2
            // error): once more on a fresh one, from stream 1.
            drop()
            (link, stream, opened) = try place(method, message)
        }
        // One reader a connection, started with its first call: for a stream,
        // its messages; for sends, only what the emulator is owed.
        if opened || onMessage != nil {
            read(link, replies: GRPCReplies(stream: onMessage == nil ? 0 : stream), onMessage ?? { _ in })
        }
    }

    /// Writes the call on this connection's link, opening one first if there is none.
    private func place(_ method: String, _ message: Data) throws -> (any EmulatorLink, UInt32, Bool) {
        try lock.withLock {
            let opened = self.link == nil
            let link = try self.link ?? openLink(emulator.port)
            if opened {
                self.link = link
                nextStream = 1
                try link.send(GRPCCall.opening)
            }
            let stream = nextStream
            nextStream += 2
            try link.send(GRPCCall(method: method, stream: stream, authority: "localhost:\(emulator.port)",
                                   token: emulator.token, message: message).bytes)
            return (link, stream, opened)
        }
    }

    /// Lets go of a link the emulator closed, so the next call opens another.
    private func drop() {
        let link = lock.withLock { defer { self.link = nil }; return self.link }
        link?.close()
    }

    private func read(_ link: any EmulatorLink, replies: GRPCReplies, _ onMessage: @escaping @Sendable (Data) -> Void) {
        Thread.detachNewThread { [self] in
            var replies = replies
            // Until the connection closes or lets go of this link.
            while lock.withLock({ !closed && self.link === link }) {
                guard let bytes = link.receive() else { continue }
                let messages = replies.push(bytes)
                let owed = replies.takeAnswers()
                if !owed.isEmpty { lock.withLock { try? link.send(owed) } }
                messages.forEach(onMessage)
            }
        }
    }
}
