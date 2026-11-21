import Foundation
import Mockable
import Testing
@testable import WebRTCKit

private let server = DatagramAddress(ip: [198, 51, 100, 4], port: 3478)
private let relayedAt = DatagramAddress(ip: [198, 51, 100, 4], port: 50001)
private let peer = DatagramAddress(ip: [203, 0, 113, 50], port: 41000)
private let neighbour = DatagramAddress(ip: [192, 168, 1, 20], port: 54400)
private let auth = TURNAuth(credentials: TURNCredentials(username: "baguette", password: "secret"), realm: "example.org", nonce: "n0nce")
private let allocation = TURNAllocation(
    server: TURNServer(address: server, credentials: auth.credentials), relayed: relayedAt, lifetime: 600, auth: auth)

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// The socket under the relay: what it sent and to whom, and a way to make
/// something arrive. A request to the server is answered with success.
private struct Socket {
    let inner = MockDatagrams()
    let sent = Box<[(Data, DatagramAddress)]>([])
    let arrive = Box<(@Sendable (Data, DatagramAddress) -> Void)?>(nil)

    init() {
        let (sent, arrive) = (sent, arrive)
        given(inner).addresses.willReturn([neighbour])
        given(inner).onReceive(.any).willProduce { arrive.value = $0 }
        given(inner).close().willReturn()
        given(inner).send(.any, to: .any).willProduce { data, to in
            sent.value.append((data, to))
            guard to == server, let request = TURNReply(data), request.type & 0x0110 == 0 else { return }
            arrive.value?(TURNMessage.encode(type: request.type | 0x0100, transactionID: request.transactionID,
                                             attributes: [], key: auth.key), server)
        }
    }
}

private func dataIndication(_ payload: [UInt8], from peer: DatagramAddress) -> Data {
    let id: [UInt8] = Array(1...12)
    return TURNMessage.encode(type: TURNMessage.dataIndication, transactionID: id, attributes: [
        (TURNMessage.xorPeerAddress, TURNMessage.xor(peer, transactionID: id)), (TURNMessage.data, payload),
    ])
}

@Suite("RelayedDatagrams")
struct RelayedDatagramsTests {
    @Test func `should hand on what a peer sent through the relay as if it came from the peer`() {
        let socket = Socket()
        let relay = RelayedDatagrams(over: socket.inner, allocation: allocation)
        let heard = Box<[(Data, DatagramAddress)]>([])
        relay.onReceive { heard.value.append(($0, $1)) }

        socket.arrive.value?(dataIndication([1, 2, 3], from: peer), server)

        #expect(heard.value.map(\.0) == [Data([1, 2, 3])] && heard.value.map(\.1) == [peer])
    }

    @Test func `should answer a peer it heard through the relay back through it, and others directly`() throws {
        let socket = Socket()
        let relay = RelayedDatagrams(over: socket.inner, allocation: allocation)
        relay.onReceive { _, _ in }
        socket.arrive.value?(dataIndication([1], from: peer), server)
        socket.arrive.value?(Data([0x16, 0xFE, 0xFD]), neighbour)

        relay.send(Data([7, 7]), to: peer)
        relay.send(Data([8, 8]), to: neighbour)

        let (wrapped, toServer) = try #require(socket.sent.value.first)
        #expect(toServer == server)
        let indication = try #require(TURNReply(wrapped))
        #expect(indication.type == TURNMessage.sendIndication && indication.peers == [peer] && indication.data == Data([7, 7]))
        #expect(socket.sent.value.last.map { $0.0 == Data([8, 8]) && $0.1 == neighbour } == true)
    }

    @Test func `should pass on what arrives directly as it came`() {
        let socket = Socket()
        let relay = RelayedDatagrams(over: socket.inner, allocation: allocation)
        let heard = Box<[DatagramAddress]>([])
        relay.onReceive { _, from in heard.value.append(from) }

        socket.arrive.value?(Data([0x80, 0x60]), neighbour)

        #expect(heard.value == [neighbour])
        #expect(relay.addresses == [neighbour])
    }

    @Test func `should let peers through, asking the server while it relays`() throws {
        let socket = Socket()
        let relay = RelayedDatagrams(over: socket.inner, allocation: allocation)
        relay.onReceive { _, _ in }

        #expect(relay.permit([peer]))

        let request = try #require(socket.sent.value.compactMap { TURNReply($0.0) }.last)
        #expect(request.type == TURNMessage.createPermissionRequest && request.peers == [peer])
    }

    @Test func `should give up its allocation when closed`() throws {
        let socket = Socket()
        let relay = RelayedDatagrams(over: socket.inner, allocation: allocation)

        relay.close()

        let release = try #require(socket.sent.value.compactMap { TURNReply($0.0) }.last)
        #expect(release.type == TURNMessage.refreshRequest && release.lifetime == 0)
        verify(socket.inner).close().called(1)
    }
}
