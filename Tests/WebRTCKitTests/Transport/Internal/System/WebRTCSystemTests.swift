import Foundation
import Testing
@testable import WebRTCKit

/// The real socket under a WebRTC viewer: bytes from one to another over loopback.
@Suite("UDPDatagrams", .tags(.system), .enabled(if: SystemTests.available))
struct UDPDatagramsTests {
    @Test(.timeLimit(.minutes(1)))
    func `should carry a datagram from one socket to another over loopback`() throws {
        let from = try UDPDatagrams(), to = try UDPDatagrams()
        defer { from.close(); to.close() }
        let arrived = DispatchSemaphore(value: 0)
        let box = ArrivedDatagram()
        to.onReceive { data, address in
            box.value = (data, address)
            arrived.signal()
        }
        let loopback = try #require(to.addresses.first { $0.ip == [127, 0, 0, 1] })

        from.send(Data("hello".utf8), to: loopback)

        #expect(arrived.wait(timeout: .now() + 5) == .success)
        #expect(box.value?.0 == Data("hello".utf8))
        #expect(box.value?.1.ip == [127, 0, 0, 1])
        #expect(box.value?.1.port == from.addresses.first?.port)
    }

    @Test(.timeLimit(.minutes(1)))
    func `should be reachable at every address it names, on one port`() throws {
        let socket = try UDPDatagrams()
        defer { socket.close() }

        #expect(!socket.addresses.isEmpty)
        #expect(Set(socket.addresses.map(\.port)).count == 1)
        #expect(socket.addresses.allSatisfy { $0.ip.count == 4 && $0.port != 0 })
    }

    @Test(.timeLimit(.minutes(1)))
    func `should take the next port of a media range when the first is in use`() throws {
        let ports = MediaPorts(48_190...48_199)
        let first = try ports.bind { try UDPDatagrams(port: $0) }
        let second = try ports.bind { try UDPDatagrams(port: $0) }
        defer { first.close(); second.close() }

        #expect(first.addresses.first?.port == 48_190)
        #expect(second.addresses.first?.port == 48_191)
    }
}

private final class ArrivedDatagram: @unchecked Sendable {
    var value: (Data, DatagramAddress)?
}

/// The real DTLS-SRTP handshake: a viewer's server side and a client standing
/// in for the browser, trading records until both export the same keys.
@Suite("BoringSSLHandshake", .tags(.system), .enabled(if: SystemTests.available))
struct BoringSSLHandshakeTests {
    /// Trades records until both sides stop answering; the last progress each made.
    private func run(_ client: BoringSSLHandshake, _ server: BoringSSLHandshake)
        -> (client: HandshakeProgress, server: HandshakeProgress) {
        var toServer = client.start()
        var last: (client: HandshakeProgress, server: HandshakeProgress) = (.continuing(replies: []), .continuing(replies: []))
        for _ in 0..<20 where !toServer.isEmpty {
            var toClient: [Data] = []
            for record in toServer {
                last.server = server.receive(record)
                toClient += last.server.replies
            }
            toServer = []
            for record in toClient {
                last.client = client.receive(record)
                toServer += last.client.replies
            }
        }
        return last
    }

    @Test(.timeLimit(.minutes(1)))
    func `should agree on the same SRTP keys with a browser whose certificate its offer named`() throws {
        let server = try BoringSSLHandshake()
        let client = try BoringSSLHandshake(role: .client)
        server.expect(client.fingerprint)
        client.expect(server.fingerprint)

        let outcome = run(client, server)

        guard case .complete(_, let serverExport) = outcome.server,
              case .complete(_, let clientExport) = outcome.client else {
            Issue.record("handshake didn't complete: \(outcome)")
            return
        }
        #expect(serverExport.count == 60)
        #expect(serverExport == clientExport)
        #expect(server.fingerprint.hasPrefix("sha-256 "))
    }

    @Test(.timeLimit(.minutes(1)))
    func `should fail a browser whose certificate isn't the one its offer named`() throws {
        let server = try BoringSSLHandshake()
        let client = try BoringSSLHandshake(role: .client)
        server.expect("sha-256 00:11:22")
        client.expect(server.fingerprint)

        #expect(run(client, server).server == .failed)
    }
}

private extension HandshakeProgress {
    var replies: [Data] {
        switch self {
        case .continuing(let replies), .complete(let replies, _): replies
        case .failed: []
        }
    }
}

/// The system resolver behind `stun:<name>`.
@Suite("HostResolver", .tags(.system), .enabled(if: SystemTests.available))
struct HostResolverTests {
    @Test(.timeLimit(.minutes(1)))
    func `should resolve a host name to its IPv4 address`() {
        #expect(HostResolver.ipv4("localhost") == [127, 0, 0, 1])
        #expect(HostResolver.ipv4("nowhere.invalid") == nil)
    }
}

/// A real TURN server, when one is named: `BAGUETTE_TURN_SERVER=turn:127.0.0.1:3478`
/// (user `baguette`, password `secret`, or `BAGUETTE_TURN_USER` / `_PASS`).
private let turnServer: TURNServer? = {
    let env = ProcessInfo.processInfo.environment
    guard let url = env["BAGUETTE_TURN_SERVER"] else { return nil }
    let credentials = TURNCredentials(username: env["BAGUETTE_TURN_USER"] ?? "baguette", password: env["BAGUETTE_TURN_PASS"] ?? "secret")
    return TURNServer(url: url, credentials: credentials, resolve: HostResolver.ipv4)
}()

private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(Data, DatagramAddress)] = []
    let arrived = DispatchSemaphore(value: 0)
    var value: [(Data, DatagramAddress)] { lock.withLock { stored } }
    func append(_ datagram: (Data, DatagramAddress)) { lock.withLock { stored.append(datagram) }; arrived.signal() }
}

/// The TURN client against a real server: allocate, let a peer through, and
/// carry datagrams both ways through the relay.
@Suite("TURN relay", .tags(.system), .enabled(if: turnServer != nil))
struct TURNRelaySystemTests {
    @Test(.timeLimit(.minutes(1)))
    func `should relay a peer's datagrams to us, and ours to it, through a real TURN server`() throws {
        let server = try #require(turnServer)
        let ours = try UDPDatagrams(), peer = try UDPDatagrams()
        defer { peer.close() }
        let peerAt = try #require(peer.addresses.first { $0.ip == [127, 0, 0, 1] })

        let allocation = try #require(TURNAllocation.allocate(on: server, through: ours, timeout: 2))
        let relay = RelayedDatagrams(over: ours, allocation: allocation)
        defer { relay.close() }
        let toUs = Heard(), toPeer = Heard()
        relay.onReceive { toUs.append(($0, $1)) }
        peer.onReceive { toPeer.append(($0, $1)) }
        #expect(relay.permit([peerAt]))

        peer.send(Data("hello".utf8), to: allocation.relayed)
        #expect(toUs.arrived.wait(timeout: .now() + 5) == .success)
        #expect(toUs.value.first?.0 == Data("hello".utf8))
        #expect(toUs.value.first?.1 == peerAt)

        relay.send(Data("back".utf8), to: peerAt)
        #expect(toPeer.arrived.wait(timeout: .now() + 5) == .success)
        #expect(toPeer.value.first?.0 == Data("back".utf8))
        #expect(toPeer.value.first?.1 == allocation.relayed)
    }
}
