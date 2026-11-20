import Foundation
import Testing
@testable import BaguetteDevice

private func hex(_ string: String) -> [UInt8] {
    stride(from: 0, to: string.count, by: 2).map {
        let start = string.index(string.startIndex, offsetBy: $0)
        return UInt8(string[start..<string.index(start, offsetBy: 2)], radix: 16)!
    }
}

/// Ours: RFC 3711 §B.3's master key and salt. The browser's: 00…0f and 10…1d.
private let ours = SRTPKeys(masterKey: hex("E1F97A0D3E018BE0D64FA32C06DE4139"),
                            masterSalt: hex("0EC675AD498AFEEBB6960B3AABE6"))
private let browsers = SRTPKeys(masterKey: Array(0..<16), masterSalt: Array(0x10..<0x1E))

private func picture(sequence: UInt16) -> RTPPacket {
    RTPPacket(marker: true, payloadType: 112, sequence: sequence, timestamp: 0x0001_0000,
              ssrc: 0xCAFE_BABE, payload: Data(hex("6501020304")))
}

@Suite("SRTPContext")
struct SRTPContextTests {
    @Test func `should derive RFC 3711's session keys from a master key and salt`() {
        let session = SRTPSessionKeys(ours, labels: .rtp)

        #expect(session.cipherKey == hex("C61E7A93744F39EE10734AFE3FF7A087"))
        #expect(session.authKey == hex("CEBE321F6FF7716B6FD4AB49AF256A156D38BAA4"))
        #expect(session.salt == hex("30CBBC08863D8C85D49DB34A9AE1"))
    }

    @Test func `should encrypt a packet's payload and sign it, leaving its header readable`() {
        var context = SRTPContext(local: ours, remote: browsers)

        // Computed independently: openssl's AES-128-CTR and Python's HMAC-SHA1.
        #expect(context.protect(picture(sequence: 0x1234))
            == Data(hex("80f0123400010000cafebabe80ff75e448f0c7562c3423cd274029")))
    }

    @Test func `should count a rollover when the sequence number wraps`() {
        var context = SRTPContext(local: ours, remote: browsers)

        _ = context.protect(picture(sequence: 0xFFFF))
        #expect(context.protect(picture(sequence: 0x0002))
            == Data(hex("80f0000200010000cafebabead75dbee93660e90bc0c8077d7ef64")))
    }

    @Test func `should read the browser's feedback once its signature checks out`() {
        let context = SRTPContext(local: ours, remote: browsers)

        // A picture loss indication from the browser, SRTCP index 7.
        #expect(context.unprotectRTCP(Data(hex("81ce0002000000014caab84e800000078baa6853b620ebd53049")))
            == Data(hex("81ce000200000001cafebabe")))
    }

    @Test func `should drop feedback whose signature doesn't check out`() {
        let context = SRTPContext(local: ours, remote: browsers)
        var tampered = hex("81ce0002000000014caab84e800000078baa6853b620ebd53049")
        tampered[9] ^= 0x01

        #expect(context.unprotectRTCP(Data(tampered)) == nil)
        #expect(context.unprotectRTCP(Data(hex("81ce0002"))) == nil)
    }

    @Test func `should drop feedback the browser didn't encrypt, even when it is signed`() {
        let context = SRTPContext(local: ours, remote: browsers)

        // E-flag clear, index 7, a valid tag: SRTCP allows it, a viewer doesn't take it.
        #expect(context.unprotectRTCP(Data(hex("81ce000200000001cafebabe00000007f72aae721efc387b470a"))) == nil)
    }

    @Test func `should split a DTLS key export into our keys and the browser's, as the DTLS server`() {
        let export = Array(UInt8(0)..<60)

        let keys = SRTPKeys.fromDTLS(export: export)

        // client key | server key | client salt | server salt (RFC 5764 §4.2); we are the server.
        #expect(keys?.local == SRTPKeys(masterKey: Array(16..<32), masterSalt: Array(46..<60)))
        #expect(keys?.remote == SRTPKeys(masterKey: Array(0..<16), masterSalt: Array(32..<46)))
        #expect(SRTPKeys.fromDTLS(export: Array(0..<59)) == nil)
    }
}
