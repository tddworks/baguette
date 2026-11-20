import Foundation
import Testing
@testable import BaguetteDevice

private func hex(_ string: String) -> Data {
    Data(stride(from: 0, to: string.count, by: 2).map {
        let start = string.index(string.startIndex, offsetBy: $0)
        return UInt8(string[start..<string.index(start, offsetBy: 2)], radix: 16)!
    })
}

/// RFC 5769 §2.1: a Binding request from an ICE agent, username "evtj:h6vY",
/// signed with the password below and fingerprinted.
private let sampleCheck = hex(
    "000100582112a442b7e7a701bc34d686fa87dfae"
    + "802200105354554e207465737420636c69656e74"
    + "002400046e0001ff"
    + "80290008932ff9b151263b36"
    + "000600096576746a3a68367659202020"
    + "000800149aeaa70cbfd8cb56781ef2b5b2d3f249c1b571a2"
    + "80280004e57a3bcf")
private let ours = ICECredentials(ufrag: "evtj", password: "VOkJxbRl1RmTxUk/WvJxBt")
private let browser = DatagramAddress(ip: [192, 0, 2, 1], port: 32853)

@Suite("STUNMessage")
struct STUNMessageTests {
    @Test func `should read the username a connectivity check names`() throws {
        let check = try #require(STUNMessage(sampleCheck))

        #expect(check.isBindingRequest)
        #expect(check.username == "evtj:h6vY")
    }

    @Test func `should answer a check addressed to our username fragment and signed with our ICE password`() throws {
        let check = try #require(STUNMessage(sampleCheck))

        // Success, the check's transaction id, XOR-MAPPED-ADDRESS 192.0.2.1:32853,
        // MESSAGE-INTEGRITY and FINGERPRINT (computed independently, with Python's hmac and zlib).
        #expect(check.answer(from: browser, ice: ours) == hex(
            "0101002c2112a442b7e7a701bc34d686fa87dfae"
            + "002000080001a147e112a643"
            + "0008001474c9371ebf3148548518699c3e3174c20dd9e68a"
            + "80280004fae4043a"))
    }

    @Test func `should refuse a check whose integrity doesn't match the ICE password`() throws {
        let check = try #require(STUNMessage(sampleCheck))

        #expect(check.answer(from: browser, ice: ICECredentials(ufrag: "evtj", password: "not-the-password")) == nil)
    }

    @Test func `should refuse a check addressed to another username fragment`() throws {
        let check = try #require(STUNMessage(sampleCheck))

        #expect(check.answer(from: browser, ice: ICECredentials(ufrag: "h6vY", password: ours.password)) == nil)
    }

    @Test func `should refuse a check that carries no integrity at all`() throws {
        // The sample's header and username alone, the length cut to match.
        let unsigned = hex("000100102112a442b7e7a701bc34d686fa87dfae" + "000600096576746a3a68367659202020")
        let check = try #require(STUNMessage(unsigned))

        #expect(check.answer(from: browser, ice: ours) == nil)
    }

    @Test func `should not answer a message that isn't a check`() throws {
        let success = try #require(STUNMessage(hex(
            "0101002c2112a442b7e7a701bc34d686fa87dfae"
            + "002000080001a147e112a643"
            + "0008001474c9371ebf3148548518699c3e3174c20dd9e68a"
            + "80280004fae4043a")))

        #expect(!success.isBindingRequest)
        #expect(success.answer(from: browser, ice: ours) == nil)
    }

    @Test func `should map an IPv6 browser's address with the transaction id too`() throws {
        let check = try #require(STUNMessage(sampleCheck))
        let v6 = DatagramAddress(ip: [0x20, 0x01, 0x0d, 0xb8, 0x12, 0x34, 0x56, 0x78,
                                      0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77], port: 32853)

        let answer = try #require(check.answer(from: v6, ice: ours))

        // RFC 5769 §2.3's mapped address: family 2, the port and address XORed
        // with the magic cookie and transaction id.
        #expect(answer[20..<44] == hex(
            "002000140002a147" + "0113a9faa5d3f179bc25f4b5bed2b9d9"))
    }

    @Test func `should read nothing from bytes that aren't STUN`() {
        #expect(STUNMessage(Data([0x00, 0x01, 0x00])) == nil)
        #expect(STUNMessage(sampleCheck.prefix(19)) == nil)
        var noCookie = sampleCheck
        noCookie[4] = 0
        #expect(STUNMessage(noCookie) == nil)
        var lengthPastTheEnd = sampleCheck
        lengthPastTheEnd[3] = 0xFF
        #expect(STUNMessage(lengthPastTheEnd) == nil)
    }

    @Test func `should tell STUN apart from DTLS and RTP on the same port by its first byte`() {
        #expect(STUNMessage.isSTUN(sampleCheck))
        #expect(!STUNMessage.isSTUN(Data([0x16, 0xFE, 0xFD])))   // a DTLS handshake record
        #expect(!STUNMessage.isSTUN(Data([0x80, 0x60, 0x00])))   // RTP
    }
}
