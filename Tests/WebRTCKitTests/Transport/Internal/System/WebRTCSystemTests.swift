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
