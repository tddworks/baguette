import Foundation

/// Hand-crafted zip bytes for the declared-size parser: filler standing
/// in for the local file records, then a real central directory + EOCD
/// declaring the given entries. The parser reads only the directory and
/// the end record, so the filler never needs to be valid local headers.
enum ZipFixture {

    static func archive(
        declaring entries: [(name: String, uncompressedBytes: UInt32)],
        comment: Data = Data()
    ) -> Data {
        let filler = Data("stand-in local records".utf8)
        var directory = Data()
        for entry in entries {
            directory.append(centralDirectoryEntry(
                name: entry.name, uncompressedBytes: entry.uncompressedBytes
            ))
        }
        var eocd = Data()
        appendU32(&eocd, 0x06054B50)                // EOCD signature
        appendU16(&eocd, 0)                         // disk number
        appendU16(&eocd, 0)                         // central dir start disk
        appendU16(&eocd, UInt16(entries.count))     // entries on this disk
        appendU16(&eocd, UInt16(entries.count))     // entries total
        appendU32(&eocd, UInt32(directory.count))   // central dir size
        appendU32(&eocd, UInt32(filler.count))      // central dir offset
        appendU16(&eocd, UInt16(comment.count))
        eocd.append(comment)
        return filler + directory + eocd
    }

    private static func centralDirectoryEntry(
        name: String, uncompressedBytes: UInt32
    ) -> Data {
        let nameBytes = Data(name.utf8)
        var entry = Data()
        appendU32(&entry, 0x02014B50)               // central dir signature
        appendU16(&entry, 0x031E)                   // made by: unix, spec 3.0
        appendU16(&entry, 20)                       // version needed
        appendU16(&entry, 0x0800)                   // flags: UTF-8 names
        appendU16(&entry, 0)                        // method: stored
        appendU16(&entry, 0)                        // time
        appendU16(&entry, 0)                        // date
        appendU32(&entry, 0)                        // crc
        appendU32(&entry, uncompressedBytes)        // compressed size
        appendU32(&entry, uncompressedBytes)        // uncompressed size
        appendU16(&entry, UInt16(nameBytes.count))
        appendU16(&entry, 0)                        // extra length
        appendU16(&entry, 0)                        // comment length
        appendU16(&entry, 0)                        // disk number start
        appendU16(&entry, 0)                        // internal attributes
        appendU32(&entry, 0x81ED0000)               // external: -rwxr-xr-x
        appendU32(&entry, 0)                        // local header offset
        entry.append(nameBytes)
        return entry
    }

    private static func appendU16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8(value >> 8))
    }

    private static func appendU32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8(value >> 24))
    }
}
