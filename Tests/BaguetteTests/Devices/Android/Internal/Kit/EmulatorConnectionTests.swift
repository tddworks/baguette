import Foundation
import Mockable
import Testing
@testable import Baguette

/// A connection to an emulator's control API, with its link — the bytes to
/// and from the emulator — stood in for: what is written, in what order, and
/// which replies come back to whom.
@Suite("EmulatorConnection")
struct EmulatorConnectionTests {
    private static let emulator = RunningEmulator(serial: "emulator-5554", avd: "baguette_pixel", port: 8554, token: "tok")

    /// Signals once something has happened, for a test to wait on.
    private final class Signal: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        func fire() { semaphore.signal() }
        func wait(seconds: Double = 5) -> Bool { semaphore.wait(timeout: .now() + seconds) == .success }
    }

    /// The emulator's side of the link: hands out what it sends, keeps what it is sent.
    private final class Link: @unchecked Sendable {
        let link = MockEmulatorLink()
        let sentSomething = Signal()
        private let lock = NSLock()
        private var inbound: [Data]
        private var _sent: [Data] = []
        var sent: [Data] { lock.withLock { _sent } }

        init(_ inbound: [Data] = []) {
            self.inbound = inbound
            given(link).send(.any).willProduce { [self] data in
                lock.withLock { _sent.append(data) }
                sentSomething.fire()
            }
            given(link).receive().willProduce { [self] in
                let next = lock.withLock { self.inbound.isEmpty ? nil : self.inbound.removeFirst() }
                if next == nil { Thread.sleep(forTimeInterval: 0.002) }
                return next
            }
            given(link).close().willReturn()
        }
    }

    private func connection(_ link: Link) -> EmulatorConnection {
        EmulatorConnection(to: Self.emulator, openLink: { _ in link.link })
    }

    @Test func `should open the connection with HTTP/2's preface before its first call`() throws {
        let link = Link()
        let connection = connection(link)

        try connection.send("sendTouch", Data([1]))
        connection.close()

        #expect(link.sent.first == GRPCCall.opening)
    }

    @Test func `should send each call on its own stream, odd and rising`() throws {
        let link = Link()
        let connection = connection(link)

        try connection.send("sendTouch", Data([1]))
        try connection.send("sendKey", Data([2]))
        connection.close()

        #expect(Array(link.sent.dropFirst()) == [
            GRPCCall(method: "sendTouch", stream: 1, authority: "localhost:8554", token: "tok", message: Data([1])).bytes,
            GRPCCall(method: "sendKey", stream: 3, authority: "localhost:8554", token: "tok", message: Data([2])).bytes,
        ])
    }

    @Test func `should hand each message of a stream on as it arrives`() throws {
        let reply = Data([0, 0, 0, 0, 2, 7, 8])
        let link = Link([GRPCFrame.bytes(kind: 0, flags: 0, stream: 1, reply)])
        let connection = connection(link)
        let received = Signal()
        let messages = Messages()

        try connection.stream("streamScreenshot", Data([0x08, 0x01])) { message in
            messages.add(message)
            received.fire()
        }

        #expect(received.wait())
        connection.close()
        #expect(messages.all == [Data([7, 8])])
    }

    @Test func `should give the emulator back what it is owed while reading`() throws {
        let link = Link([GRPCFrame.bytes(kind: 4, flags: 0, stream: 0, Data())])
        let connection = connection(link)

        try connection.stream("streamScreenshot", Data()) { _ in }
        for _ in 0..<500 where !link.sent.contains(GRPCFrame.bytes(kind: 4, flags: 1, stream: 0, Data())) {
            Thread.sleep(forTimeInterval: 0.002)
        }
        connection.close()

        #expect(link.sent.contains(GRPCFrame.bytes(kind: 4, flags: 1, stream: 0, Data())))
    }

    @Test func `should carry a call on a fresh link when the emulator has closed the old one`() throws {
        let closedByEmulator = MockEmulatorLink()
        given(closedByEmulator).send(.any).willThrow(Closed())
        given(closedByEmulator).receive().willReturn(nil)
        given(closedByEmulator).close().willReturn()
        let fresh = Link()
        let links = Links([closedByEmulator, fresh.link])
        let connection = EmulatorConnection(to: Self.emulator, openLink: { _ in links.next() })

        try connection.send("sendTouch", Data([1]))
        connection.close()

        #expect(fresh.sent == [
            GRPCCall.opening,
            GRPCCall(method: "sendTouch", stream: 1, authority: "localhost:8554", token: "tok", message: Data([1])).bytes,
        ])
    }

    @Test func `should refuse a call when no fresh link reaches the emulator either`() {
        let closedByEmulator = MockEmulatorLink()
        given(closedByEmulator).send(.any).willThrow(Closed())
        given(closedByEmulator).receive().willReturn(nil)
        given(closedByEmulator).close().willReturn()
        let connection = EmulatorConnection(to: Self.emulator, openLink: { _ in closedByEmulator })

        #expect(throws: Closed.self) { try connection.send("sendTouch", Data([1])) }
    }

    private struct Closed: Error {}

    /// Hands out the links in order, as each reconnect asks for one.
    private final class Links: @unchecked Sendable {
        private let lock = NSLock()
        private var links: [any EmulatorLink]
        init(_ links: [any EmulatorLink]) { self.links = links }
        func next() -> any EmulatorLink { lock.withLock { links.count > 1 ? links.removeFirst() : links[0] } }
    }

    @Test func `should tell a stream it ended when the emulator closes its link`() throws {
        let link = MockEmulatorLink()
        given(link).send(.any).willReturn()
        given(link).receive().willThrow(Closed())
        given(link).close().willReturn()
        let connection = EmulatorConnection(to: Self.emulator, openLink: { _ in link })
        let ended = Signal()

        try connection.stream("streamScreenshot", Data(), onMessage: { _ in }, onEnd: { ended.fire() })

        #expect(ended.wait())
        connection.close()
    }

    @Test func `should not tell a stream it ended when the connection itself was closed`() throws {
        let link = Link()
        let connection = connection(link)
        let ended = Signal()

        try connection.stream("streamScreenshot", Data(), onMessage: { _ in }, onEnd: { ended.fire() })
        connection.close()

        #expect(!ended.wait(seconds: 0.2))
    }

    @Test func `should refuse a call once closed, opening no link`() {
        let opened = Counter()
        let connection = EmulatorConnection(to: Self.emulator, openLink: { _ in opened.add(); return Link().link })

        connection.close()

        #expect(throws: (any Error).self) { try connection.send("sendTouch", Data([1])) }
        #expect(opened.count == 0)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        func add() { lock.withLock { _count += 1 } }
    }

    @Test func `should close its link when closed`() throws {
        let link = Link()
        let connection = connection(link)
        try connection.send("sendTouch", Data([1]))

        connection.close()

        verify(link.link).close().called(1)
    }

    private final class Messages: @unchecked Sendable {
        private let lock = NSLock()
        private var _all: [Data] = []
        var all: [Data] { lock.withLock { _all } }
        func add(_ message: Data) { lock.withLock { _all.append(message) } }
    }
}
