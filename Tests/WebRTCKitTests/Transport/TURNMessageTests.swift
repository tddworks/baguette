import Foundation
import Testing
@testable import WebRTCKit

private let id: [UInt8] = Array(1...12)
private let credentials = TURNCredentials(username: "baguette", password: "secret")
private let peer = DatagramAddress(ip: [203, 0, 113, 50], port: 41000)
private let relayed = DatagramAddress(ip: [198, 51, 100, 4], port: 50001)

/// XOR-<something>-ADDRESS's value, as a server writes it.
private func xorAddress(_ address: DatagramAddress) -> [UInt8] {
    let key: [UInt8] = [0x21, 0x12, 0xA4, 0x42] + id
    let port = address.port ^ 0x2112
    return [0, 1, UInt8(port >> 8), UInt8(port & 0xFF)] + zip(address.ip, key).map { $0 ^ $1 }
}

@Suite("TURNMessage")
struct TURNMessageTests {
    @Test func `should ask for a UDP relay, first without credentials`() throws {
        let request = TURNMessage.allocate(transactionID: id, auth: nil)

        let read = try #require(TURNReply(request))
        #expect(read.type == TURNMessage.allocateRequest)
        #expect(read.attributes[TURNMessage.requestedTransport] == [17, 0, 0, 0])
        #expect(read.attributes[TURNMessage.messageIntegrity] == nil)
    }

    @Test func `should read the realm and nonce a server's challenge gives`() throws {
        let challenge = TURNMessage.encode(type: TURNMessage.allocateError, transactionID: id, attributes: [
            (TURNMessage.errorCode, [0, 0, 4, 1] + [UInt8]("Unauthorized".utf8)),
            (TURNMessage.realm, [UInt8]("example.org".utf8)),
            (TURNMessage.nonce, [UInt8]("f//499k954d6OL34oL9FSTvy64sA".utf8)),
        ])

        let reply = try #require(TURNReply(challenge))
        #expect(reply.errorCode == 401)
        #expect(reply.realm == "example.org" && reply.nonce == "f//499k954d6OL34oL9FSTvy64sA")
    }

    @Test func `should sign a request with its long-term key, as the server checks it`() throws {
        let auth = TURNAuth(credentials: credentials, realm: "example.org", nonce: "n0nce")
        let request = TURNMessage.allocate(transactionID: id, auth: auth)

        let read = try #require(TURNReply(request))
        #expect(read.attributes[TURNMessage.username] == [UInt8]("baguette".utf8))
        #expect(read.isSigned(with: auth.key))
        #expect(!read.isSigned(with: TURNAuth(credentials: TURNCredentials(username: "baguette", password: "wrong"),
                                              realm: "example.org", nonce: "n0nce").key))
        // The key is MD5("baguette:example.org:secret"), as `md5` computes it.
        #expect(auth.key.map { String(format: "%02x", $0) }.joined() == "67b4cab1e71c3b9d45df9a454c430d8a")
    }

    @Test func `should read the relayed address and lifetime its allocation was given`() throws {
        let success = TURNMessage.encode(type: TURNMessage.allocateSuccess, transactionID: id, attributes: [
            (TURNMessage.xorRelayedAddress, xorAddress(relayed)),
            (TURNMessage.lifetime, [0, 0, 0x02, 0x58]),
        ])

        let reply = try #require(TURNReply(success))
        #expect(reply.relayed == relayed)
        #expect(reply.lifetime == 600)
    }

    @Test func `should ask permission for each peer`() throws {
        let other = DatagramAddress(ip: [192, 0, 2, 9], port: 1)
        let request = try #require(TURNReply(TURNMessage.createPermission(
            peers: [peer, other], transactionID: id, auth: TURNAuth(credentials: credentials, realm: "r", nonce: "n"))))

        #expect(request.type == TURNMessage.createPermissionRequest)
        #expect(request.peers == [peer, other])
    }

    @Test func `should wrap data for a peer, and read data a peer sent through the relay`() throws {
        let send = try #require(TURNReply(TURNMessage.send(Data([1, 2, 3]), to: peer, transactionID: id)))
        #expect(send.type == TURNMessage.sendIndication && send.peers == [peer] && send.data == Data([1, 2, 3]))

        let data = TURNMessage.encode(type: TURNMessage.dataIndication, transactionID: id, attributes: [
            (TURNMessage.xorPeerAddress, xorAddress(peer)), (TURNMessage.data, [9, 8, 7]),
        ])
        let received = try #require(TURNReply(data))
        #expect(received.type == TURNMessage.dataIndication && received.peers == [peer] && received.data == Data([9, 8, 7]))
    }

    @Test func `should give up its allocation with a zero lifetime`() throws {
        let release = try #require(TURNReply(TURNMessage.refresh(
            lifetime: 0, transactionID: id, auth: TURNAuth(credentials: credentials, realm: "r", nonce: "n"))))

        #expect(release.type == TURNMessage.refreshRequest && release.lifetime == 0)
    }
}
