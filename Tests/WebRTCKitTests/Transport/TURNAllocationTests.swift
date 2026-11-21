import Foundation
import Mockable
import Testing
@testable import WebRTCKit

private let server = DatagramAddress(ip: [198, 51, 100, 4], port: 3478)
private let relayed = DatagramAddress(ip: [198, 51, 100, 4], port: 50001)
private let browser = DatagramAddress(ip: [203, 0, 113, 50], port: 41000)
private let credentials = TURNCredentials(username: "baguette", password: "secret")

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// A TURN server behind a mock socket: it challenges an unsigned request with
/// 401, and answers one signed with `password` — an allocation, a permission
/// or a refresh. Everything it was asked, it keeps.
private struct FakeServer {
    let datagrams = MockDatagrams()
    let asked = Box<[TURNReply]>([])
    let handler = Box<(@Sendable (Data, DatagramAddress) -> Void)?>(nil)

    init(password: String = "secret", answers: Bool = true) {
        let (asked, handler) = (asked, handler)
        let key = TURNAuth(credentials: TURNCredentials(username: "baguette", password: password), realm: "example.org", nonce: "n0nce").key
        given(datagrams).onReceive(.any).willProduce { handler.value = $0 }
        given(datagrams).send(.any, to: .any).willProduce { data, to in
            guard to == server, let request = TURNReply(data) else { return }
            asked.value.append(request)
            guard answers else { return }
            let reply: Data
            if request.type == TURNMessage.sendIndication {
                return
            } else if !request.isSigned(with: key) {
                reply = TURNMessage.encode(type: request.type | 0x0110, transactionID: request.transactionID, attributes: [
                    (TURNMessage.errorCode, [0, 0, 4, 1]), (TURNMessage.realm, [UInt8]("example.org".utf8)),
                    (TURNMessage.nonce, [UInt8]("n0nce".utf8)),
                ])
            } else if request.type == TURNMessage.allocateRequest {
                reply = TURNMessage.encode(type: TURNMessage.allocateSuccess, transactionID: request.transactionID, attributes: [
                    (TURNMessage.xorRelayedAddress, TURNMessage.xor(relayed, transactionID: request.transactionID)),
                    (TURNMessage.lifetime, [0, 0, 0x02, 0x58]),
                ], key: key)
            } else {
                reply = TURNMessage.encode(type: request.type | 0x0100, transactionID: request.transactionID, attributes: [], key: key)
            }
            handler.value?(reply, server)
        }
    }
}

@Suite("TURNAllocation")
struct TURNAllocationTests {
    @Test func `should get a relayed address, answering the server's challenge with its credentials`() throws {
        let fake = FakeServer()

        let allocation = try #require(TURNAllocation.allocate(
            on: TURNServer(address: server, credentials: credentials), through: fake.datagrams, timeout: 1))

        #expect(allocation.relayed == relayed)
        #expect(allocation.lifetime == 600)
        #expect(fake.asked.value.map(\.type) == [TURNMessage.allocateRequest, TURNMessage.allocateRequest])
        #expect(fake.asked.value.last?.isSigned(with: allocation.auth.key) == true)
    }

    @Test func `should get no relay with credentials the server turns down`() {
        let fake = FakeServer(password: "the server's own")

        #expect(TURNAllocation.allocate(
            on: TURNServer(address: server, credentials: credentials), through: fake.datagrams, timeout: 0.2) == nil)
    }

    @Test func `should get no relay from a server that doesn't answer`() {
        let fake = FakeServer(answers: false)

        #expect(TURNAllocation.allocate(
            on: TURNServer(address: server, credentials: credentials), through: fake.datagrams, timeout: 0.1) == nil)
    }

    @Test func `should let the browser's addresses through, signed`() throws {
        let fake = FakeServer()
        let allocation = try #require(TURNAllocation.allocate(
            on: TURNServer(address: server, credentials: credentials), through: fake.datagrams, timeout: 1))

        #expect(allocation.permit([browser], through: fake.datagrams, timeout: 1))

        let request = try #require(fake.asked.value.last)
        #expect(request.type == TURNMessage.createPermissionRequest && request.peers == [browser])
        #expect(request.isSigned(with: allocation.auth.key))
    }

    @Test func `should keep its allocation, and give it up`() throws {
        let fake = FakeServer()
        let allocation = try #require(TURNAllocation.allocate(
            on: TURNServer(address: server, credentials: credentials), through: fake.datagrams, timeout: 1))

        #expect(allocation.refresh(lifetime: 600, through: fake.datagrams, timeout: 1))
        #expect(allocation.refresh(lifetime: 0, through: fake.datagrams, timeout: 1))

        #expect(fake.asked.value.suffix(2).map(\.lifetime) == [600, 0])
    }
}

@Suite("TURNServer")
struct TURNServerTests {
    private let resolve: @Sendable (String) -> [UInt8]? = { $0 == "turn.example.com" ? [198, 51, 100, 4] : nil }

    @Test func `should read a TURN server written as WebRTC writes one`() {
        #expect(TURNServer(url: "turn:turn.example.com:3478", credentials: credentials, resolve: resolve)?.address == server)
        #expect(TURNServer(url: "turn:turn.example.com", credentials: credentials, resolve: resolve)?.address == server)
        #expect(TURNServer(url: "turn:turn.example.com:3478?transport=udp", credentials: credentials, resolve: resolve)?.address == server)
        #expect(TURNServer(url: "turn:turn.example.com", credentials: credentials, resolve: resolve)?.url == "turn:turn.example.com")
    }

    @Test func `should read no TURN server from what isn't one, or over TCP`() {
        for written in ["stun:turn.example.com", "turn:", "turn:turn.example.com:x", "turn:turn.example.com?transport=tcp", "turns:turn.example.com"] {
            #expect(TURNServer(url: written, credentials: credentials, resolve: resolve) == nil, "\(written)")
        }
    }
}
