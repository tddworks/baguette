import Foundation

/// DTLS's output, cut into datagrams. A memory BIO hands over a handshake
/// flight as one run of records; sent whole, a certificate flight is bigger
/// than a 1280-byte tunnel carries. DTLS lets several records share a datagram
/// (RFC 6347 §4.1.1), so whole records are packed up to the limit, and a record
/// is never cut.
public enum DTLSRecords {
    private static let headerSize = 13

    public static func datagrams(packing bytes: [UInt8], upTo limit: Int) -> [Data] {
        var datagrams: [Data] = []
        var current: [UInt8] = []
        var at = 0
        while at < bytes.count {
            var end = bytes.count   // a partial record goes along as it is
            if at + headerSize <= bytes.count {
                let length = Int(bytes[at + 11]) << 8 | Int(bytes[at + 12])
                end = min(at + headerSize + length, bytes.count)
            }
            let record = bytes[at..<end]
            if !current.isEmpty, current.count + record.count > limit {
                datagrams.append(Data(current))
                current = []
            }
            current += record
            at = end
        }
        if !current.isEmpty { datagrams.append(Data(current)) }
        return datagrams
    }
}
