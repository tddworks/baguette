import Foundation
import Mockable
import Testing
@testable import WebRTCKit

private let server = DatagramAddress(ip: [198, 51, 100, 4], port: 3478)
private let outside = DatagramAddress(ip: [203, 0, 113, 7], port: 61000)
private let id: [UInt8] = Array(1...12)

/// A Binding success reporting `address`, for transaction `id`, as a server writes it.
private func success(reporting address: DatagramAddress, id: [UInt8]) -> Data {
    let cookie: [UInt8] = [0x21, 0x12, 0xA4, 0x42]
    let port = address.port ^ 0x2112
    let ip = zip(address.ip, cookie + id).map { $0 ^ $1 }
    let attribute: [UInt8] = [0x00, 0x20, 0x00, 0x08, 0, 1, UInt8(port >> 8), UInt8(port & 0xFF)] + ip
    return Data([0x01, 0x01, 0x00, UInt8(attribute.count)] + cookie + id + attribute)
}

private final class Handler: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (@Sendable (Data, DatagramAddress) -> Void)?
    var value: (@Sendable (Data, DatagramAddress) -> Void)? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// A socket whose server answers each request with `answer`, if any.
private func socket(answering answer: (@Sendable () -> (Data, DatagramAddress))?) -> MockDatagrams {
    let datagrams = MockDatagrams()
    let handler = Handler()
    given(datagrams).onReceive(.any).willProduce { handler.value = $0 }
    given(datagrams).send(.any, to: .any).willProduce { _, _ in
        guard let answer else { return }
        let (data, from) = answer()
        handler.value?(data, from)
    }
    return datagrams
}

@Suite("STUNServer")
struct STUNServerTests {
    @Test func `should learn the address a STUN server sees it at`() {
        let datagrams = socket { (success(reporting: outside, id: id), server) }

        let seen = STUNServer(address: server).publicAddress(through: datagrams, timeout: 1, transactionID: id)

        #expect(seen == outside)
        verify(datagrams).send(.value(STUNMessage.bindingRequest(transactionID: id)), to: .value(server)).called(1)
    }

    @Test func `should learn nothing from a server that doesn't answer in time`() {
        let datagrams = socket(answering: nil)

        #expect(STUNServer(address: server).publicAddress(through: datagrams, timeout: 0.05, transactionID: id) == nil)
        // Asked again halfway, in case the first request was lost.
        verify(datagrams).send(.any, to: .value(server)).called(2)
    }

    @Test func `should take no answer to another question, or from anyone but its server`() {
        let otherQuestion = socket { (success(reporting: outside, id: Array(repeating: 9, count: 12)), server) }
        let stranger = socket { (success(reporting: outside, id: id), DatagramAddress(ip: [10, 0, 0, 9], port: 3478)) }

        #expect(STUNServer(address: server).publicAddress(through: otherQuestion, timeout: 0.05, transactionID: id) == nil)
        #expect(STUNServer(address: server).publicAddress(through: stranger, timeout: 0.05, transactionID: id) == nil)
    }

    @Test func `should read a STUN server written as WebRTC writes one`() {
        let resolve: @Sendable (String) -> [UInt8]? = { $0 == "stun.example.com" ? [198, 51, 100, 4] : nil }

        #expect(STUNServer(url: "stun:stun.example.com:3478", resolve: resolve)?.address == server)
        #expect(STUNServer(url: "stun:stun.example.com", resolve: resolve)?.address == server)
        #expect(STUNServer(url: "stun:198.51.100.4:19302", resolve: { _ in nil })?.address
            == DatagramAddress(ip: [198, 51, 100, 4], port: 19302))
    }

    @Test func `should read no STUN server from what isn't one`() {
        let resolve: @Sendable (String) -> [UInt8]? = { _ in [198, 51, 100, 4] }
        for written in ["turn:stun.example.com", "stun:", "stun.example.com:3478", "stun:host:port", "stun:host:70000"] {
            #expect(STUNServer(url: written, resolve: resolve) == nil, "\(written)")
        }
        #expect(STUNServer(url: "stun:nowhere.invalid", resolve: { _ in nil }) == nil)
    }
}
