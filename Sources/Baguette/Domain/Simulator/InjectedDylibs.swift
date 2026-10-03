import Foundation

/// The dylibs currently listed in a simulator's `DYLD_INSERT_LIBRARIES`.
///
/// ## Why this is a value and not just a string
///
/// That env var is **one string for the whole simulator's launchd domain**,
/// and baguette has more than one feature that wants a dylib inside apps —
/// the virtual camera, and motion. Writing a single path (and unsetting the
/// whole variable on teardown) means the second feature to arm silently
/// disarms the first, and whichever stops first disarms the other.
///
/// So arming is a **read-modify-write**: parse what's there, add or remove
/// one entry by dylib filename, write the join back. All of that merging is
/// modelled here so it's unit-tested, leaving the adapter a thin wrapper
/// around two `launchctl` calls.
struct InjectedDylibs: Equatable, Sendable {

    /// Absolute paths, in the order dyld will load them.
    let paths: [String]

    var isEmpty: Bool { paths.isEmpty }

    /// The colon-joined value to hand `launchctl setenv`. Empty when
    /// nothing is armed — the caller should `unsetenv` rather than set
    /// this, since dyld treats an empty entry as a path it failed to load.
    var environmentValue: String { paths.joined(separator: ":") }

    /// Reads an existing `DYLD_INSERT_LIBRARIES` value, keeping only
    /// segments that are actually absolute dylib paths.
    ///
    /// The injection adapter supplies stdout only. Empty colon segments
    /// and surrounding whitespace are omitted; malformed segments are not
    /// written back as library paths.
    static func parsing(_ environmentValue: String?) -> InjectedDylibs {
        let paths = (environmentValue ?? "")
            .split(separator: ":")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter(isDylibPath)
        return InjectedDylibs(paths: paths)
    }

    /// dyld only accepts absolute paths, and every dylib baguette injects
    /// ends in `.dylib`. Anything else in the value is noise.
    private static func isDylibPath(_ candidate: String) -> Bool {
        candidate.hasPrefix("/") && candidate.hasSuffix(".dylib")
            && !candidate.contains("\n")
    }

    /// Arms `path`, replacing any other build of the **same dylib**.
    ///
    /// Every release installs under a fresh sha-keyed directory (iOS 26's
    /// simulator dyld page-hash cache rejects a replaced dylib at the same
    /// path), so the same dylib legitimately arrives under a new path.
    /// Leaving both in the list is a load error, not a merge.
    func adding(_ path: String) -> InjectedDylibs {
        InjectedDylibs(paths: removing(path).paths + [path])
    }

    /// Disarms one dylib, identified by **filename** — the sha-keyed
    /// directory differs per release, so the last path component is what
    /// identifies a feature's dylib. Anything armed by someone else is
    /// left untouched.
    func removing(_ path: String) -> InjectedDylibs {
        let name = (path as NSString).lastPathComponent
        return InjectedDylibs(
            paths: paths.filter { ($0 as NSString).lastPathComponent != name })
    }
}
