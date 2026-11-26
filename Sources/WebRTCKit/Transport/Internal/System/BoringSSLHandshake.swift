import CNIOBoringSSL
import Foundation

/// The `Handshake` a viewer runs: BoringSSL's DTLS over memory BIOs, offering
/// SRTP_AES128_CM_SHA1_80. It trusts any certificate during the handshake and
/// then asks `CertificateFingerprint` whether the peer's is the one expected.
public final class BoringSSLHandshake: Handshake, @unchecked Sendable {
    public enum Role: Sendable { case server, client }

    private let lock = NSLock()
    private let certificate: SelfSignedCertificate
    private let context: OpaquePointer
    private let ssl: OpaquePointer
    private let incoming: OpaquePointer
    private let outgoing: OpaquePointer
    private var expected = ""

    public init(role: Role = .server) throws {
        certificate = try SelfSignedCertificate()
        guard let context = SSL_CTX_new(DTLS_method()),
              SSL_CTX_use_certificate(context, certificate.x509) == 1,
              SSL_CTX_use_PrivateKey(context, certificate.key) == 1,
              SSL_CTX_set_tlsext_use_srtp(context, "SRTP_AES128_CM_SHA1_80") == 0
        else { throw SelfSignedCertificate.Failure(step: "context") }
        SSL_CTX_set_custom_verify(context, SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT) { _, _ in
            ssl_verify_ok
        }
        guard let ssl = SSL_new(context),
              let incoming = BIO_new(BIO_s_mem()),
              let outgoing = BIO_new(BIO_s_mem())
        else { throw SelfSignedCertificate.Failure(step: "session") }
        SSL_set_bio(ssl, incoming, outgoing)
        SSL_set_mtu(ssl, 1100)
        role == .server ? SSL_set_accept_state(ssl) : SSL_set_connect_state(ssl)
        (self.context, self.ssl, self.incoming, self.outgoing) = (context, ssl, incoming, outgoing)
    }

    deinit {
        SSL_free(ssl)
        SSL_CTX_free(context)
    }

    public var fingerprint: String { certificate.fingerprint.sdp }

    /// The peer's certificate, as its offer (or answer) named it.
    public func expect(_ fingerprint: String) { lock.withLock { expected = fingerprint } }

    /// A client's first flight; a server waits for the browser's.
    func start() -> [Data] { lock.withLock { _ = SSL_do_handshake(ssl); return drain() } }

    public func receive(_ record: Data) -> HandshakeProgress {
        lock.withLock {
            _ = record.withUnsafeBytes { BIO_write(incoming, $0.baseAddress, Int32($0.count)) }
            let result = SSL_do_handshake(ssl)
            guard result == 1 else {
                let error = SSL_get_error(ssl, result)
                return error == SSL_ERROR_WANT_READ ? .continuing(replies: drain()) : .failed
            }
            guard let peer = SSL_get_peer_certificate(ssl) else { return .failed }
            defer { X509_free(peer) }
            var export = [UInt8](repeating: 0, count: 60)
            let label = "EXTRACTOR-dtls_srtp"
            guard SelfSignedCertificate.fingerprint(of: peer).matches(expected),
                  SSL_get_selected_srtp_profile(ssl) != nil,
                  SSL_export_keying_material(ssl, &export, 60, label, label.utf8.count, nil, 0, 0) == 1
            else { return .failed }
            return .complete(replies: drain(), srtpExport: export)
        }
    }

    public func resend() -> [Data] {
        lock.withLock { _ = DTLSv1_handle_timeout(ssl); return drain() }
    }

    /// What DTLS wrote, as datagrams that fit a 1280-byte tunnel.
    private func drain() -> [Data] {
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let read = BIO_read(outgoing, &chunk, Int32(chunk.count))
            guard read > 0 else { break }
            bytes += chunk.prefix(Int(read))
        }
        return DTLSRecords.datagrams(packing: bytes, upTo: 1200)
    }
}
