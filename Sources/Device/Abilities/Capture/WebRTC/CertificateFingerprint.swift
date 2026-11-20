import Foundation

/// A certificate's SHA-256 digest as SDP names it (RFC 8122):
/// "sha-256 6B:8B:…". A viewer puts its own in the answer, and its handshake
/// fails unless the browser's certificate matches the one its offer named.
public struct CertificateFingerprint: Equatable, Sendable {
    public let sha256: [UInt8]

    public init(sha256: [UInt8]) { self.sha256 = sha256 }

    public var sdp: String {
        "sha-256 " + sha256.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// Whether `offered` ("<hash> <hex:hex:…>") names this certificate.
    public func matches(_ offered: String) -> Bool {
        offered.uppercased() == sdp.uppercased()
    }
}
