import Foundation
import Testing
@testable import BaguetteDevice

@Suite("CertificateFingerprint")
struct CertificateFingerprintTests {
    @Test func `should write a SHA-256 digest the way SDP names a certificate`() {
        let fingerprint = CertificateFingerprint(sha256: [0x6B, 0x8B, 0x0A, 0xFF])

        #expect(fingerprint.sdp == "sha-256 6B:8B:0A:FF")
    }

    @Test func `should match the certificate an offer names, whatever its letter case`() {
        let fingerprint = CertificateFingerprint(sha256: [0x6B, 0x8B, 0x0A, 0xFF])

        #expect(fingerprint.matches("sha-256 6b:8b:0a:ff"))
        #expect(fingerprint.matches("SHA-256 6B:8B:0A:FF"))
    }

    @Test func `should not match another certificate, nor a digest named with another hash`() {
        let fingerprint = CertificateFingerprint(sha256: [0x6B, 0x8B, 0x0A, 0xFF])

        #expect(!fingerprint.matches("sha-256 6B:8B:0A:FE"))
        #expect(!fingerprint.matches("sha-1 6B:8B:0A:FF"))
        #expect(!fingerprint.matches(""))
    }
}

/// One DTLS record: content type, version, epoch, sequence, length, body.
private func record(_ size: Int, type: UInt8 = 22) -> [UInt8] {
    [type, 0xFE, 0xFD, 0, 0, 0, 0, 0, 0, 0, 1, UInt8(size >> 8), UInt8(size & 0xFF)]
        + [UInt8](repeating: 0xAB, count: size)
}

@Suite("DTLSRecords")
struct DTLSRecordsTests {
    @Test func `should pack whole records into datagrams no bigger than the limit`() {
        let a = record(500), b = record(500), c = record(900)

        let datagrams = DTLSRecords.datagrams(packing: a + b + c, upTo: 1200)

        #expect(datagrams == [Data(a + b), Data(c)])
    }

    @Test func `should send a record bigger than the limit on its own rather than cut it`() {
        let big = record(1500), small = record(10)

        #expect(DTLSRecords.datagrams(packing: big + small, upTo: 1200) == [Data(big), Data(small)])
    }

    @Test func `should carry a trailing partial record along rather than drop it`() {
        let whole = record(10)
        let partial = Array(record(40).prefix(20))

        #expect(DTLSRecords.datagrams(packing: whole + partial, upTo: 1200) == [Data(whole + partial)])
        #expect(DTLSRecords.datagrams(packing: [], upTo: 1200).isEmpty)
    }
}
