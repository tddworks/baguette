import Foundation

/// A zip that carries an app — how a folder-form `.app` bundle travels
/// over HTTP. The browser can't upload a directory as one file, so the
/// drop target packs the bundle into a stored zip and posts that; a
/// user-zipped `.app` arrives the same way. `simctl install` doesn't
/// take zips, so unlike `AppBundle` this value isn't installable as-is:
/// it must be extracted first (`ditto -x -k`), then the single `.app`
/// inside is installed through the normal `AppBundle` path.
///
/// All three answers here are pure: `at(_:)` classifies by extension
/// (no disk access, so the serve route can reject before reading the
/// body), `extractArguments(to:)` projects the ditto argv tail, and
/// `installableApp(amongExtracted:)` picks the app from the extracted
/// top-level names. The Infrastructure adapter (`SimctlApps`) just runs
/// the two subprocesses around them.
public struct AppArchive: Equatable, Sendable {
    public let path: URL

    public init(path: URL) {
        self.path = path
    }

    /// Classify a host file as an app archive, or `nil` when it isn't
    /// a zip. `.ipa` is deliberately excluded — it installs directly
    /// via `AppBundle` without an extraction step.
    public static func at(_ path: URL) -> AppArchive? {
        guard path.pathExtension.lowercased() == "zip" else { return nil }
        return AppArchive(path: path)
    }

    /// The argv tail handed to `/usr/bin/ditto -x -k <zip> <dest>`.
    /// ditto (not `unzip`) because it restores the unix modes stored
    /// in the zip's external attributes — the app's main executable
    /// must come out executable.
    public func extractArguments(to destination: URL) -> [String] {
        ["-x", "-k", path.path, destination.path]
    }

    /// Pick the app from the archive's extracted top-level entries:
    /// exactly one `.app` (case-insensitive), after ignoring Finder
    /// junk (`__MACOSX`) and dotfiles. Two apps are ambiguous —
    /// refused (`nil`) rather than guessed at.
    public static func installableApp(amongExtracted entries: [String]) -> String? {
        let apps = entries.filter {
            !$0.hasPrefix(".") && $0 != "__MACOSX"
                && ($0 as NSString).pathExtension.lowercased() == "app"
        }
        return apps.count == 1 ? apps[0] : nil
    }

    /// The total uncompressed size the archive's central directory
    /// declares — readable without extracting anything, so an obvious
    /// zip bomb is refused before `ditto` writes a single byte. `nil`
    /// when the bytes don't parse as a zip (no end-of-central-directory
    /// record, directory out of bounds, entry count past the
    /// directory's end). A forged-low declaration slips through here;
    /// the post-extraction measurement is the backstop. A zip64 size
    /// marker (`0xFFFFFFFF`) sums at its literal ~4.3 GB value — the
    /// real size is at least that, so an over-cap verdict stands.
    public static func declaredUncompressedBytes(in data: Data) -> Int64? {
        // The end record is 22 fixed bytes plus a comment of up to
        // 0xFFFF — scan back from the end for its signature.
        let eocdLength = 22
        guard data.count >= eocdLength else { return nil }
        let base = data.startIndex
        var eocd = -1
        var candidate = data.count - eocdLength
        let lowest = max(0, data.count - eocdLength - 0xFFFF)
        while candidate >= lowest {
            if u32(data, base + candidate) == 0x06054B50 { eocd = candidate; break }
            candidate -= 1
        }
        guard eocd >= 0 else { return nil }

        let entryCount = Int(u16(data, base + eocd + 10))
        let directorySize = Int(u32(data, base + eocd + 12))
        let directoryStart = Int(u32(data, base + eocd + 16))
        let directoryEnd = directoryStart + directorySize
        guard directoryEnd <= eocd else { return nil }

        var position = directoryStart
        var total: Int64 = 0
        for _ in 0..<entryCount {
            guard position + 46 <= directoryEnd,
                  u32(data, base + position) == 0x02014B50 else { return nil }
            total += Int64(u32(data, base + position + 24))
            let nameLength = Int(u16(data, base + position + 28))
            let extraLength = Int(u16(data, base + position + 30))
            let commentLength = Int(u16(data, base + position + 32))
            position += 46 + nameLength + extraLength + commentLength
        }
        return total
    }

    private static func u16(_ data: Data, _ index: Data.Index) -> UInt16 {
        UInt16(data[index]) | UInt16(data[index + 1]) << 8
    }

    private static func u32(_ data: Data, _ index: Data.Index) -> UInt32 {
        UInt32(data[index])
            | UInt32(data[index + 1]) << 8
            | UInt32(data[index + 2]) << 16
            | UInt32(data[index + 3]) << 24
    }
}
