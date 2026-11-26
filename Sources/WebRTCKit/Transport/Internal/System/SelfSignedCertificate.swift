import CNIOBoringSSL
import Foundation

/// A fresh P-256 key and a self-signed certificate for one viewer's DTLS. WebRTC
/// trusts it by fingerprint (the answer's `a=fingerprint`), not by issuer.
final class SelfSignedCertificate: @unchecked Sendable {
    let key: OpaquePointer
    let x509: OpaquePointer

    struct Failure: Error { let step: String }

    init() throws {
        guard let key = EVP_PKEY_new(),
              let ec = EC_KEY_new_by_curve_name(NID_X9_62_prime256v1),
              EC_KEY_generate_key(ec) == 1,
              EVP_PKEY_assign_EC_KEY(key, ec) == 1 else { throw Failure(step: "key") }
        guard let x509 = X509_new() else { throw Failure(step: "certificate") }
        X509_set_version(x509, Int(X509_VERSION_3))
        ASN1_INTEGER_set(X509_get_serialNumber(x509), Int.random(in: 1...Int(Int32.max)))
        X509_gmtime_adj(X509_getm_notBefore(x509), -3600)
        X509_gmtime_adj(X509_getm_notAfter(x509), 30 * 24 * 3600)
        let name = X509_get_subject_name(x509)
        X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, "baguette", -1, -1, 0)
        X509_set_issuer_name(x509, name)
        guard X509_set_pubkey(x509, key) == 1,
              X509_sign(x509, key, EVP_sha256()) > 0 else { throw Failure(step: "sign") }
        self.key = key
        self.x509 = x509
    }

    deinit {
        X509_free(x509)
        EVP_PKEY_free(key)
    }

    var fingerprint: CertificateFingerprint { Self.fingerprint(of: x509) }

    static func fingerprint(of certificate: OpaquePointer) -> CertificateFingerprint {
        var digest = [UInt8](repeating: 0, count: 32)
        var length: UInt32 = 0
        X509_digest(certificate, EVP_sha256(), &digest, &length)
        return CertificateFingerprint(sha256: Array(digest.prefix(Int(length))))
    }
}
