import Foundation

/// Selection criteria for the simulator's unified-log stream. Maps
/// 1:1 onto the flags the booted simulator's `/usr/bin/log stream`
/// understands — we don't reinvent predicate parsing, just project
/// the value type into argv that we hand to `SimDevice.spawn…`.
public struct LogFilter: Equatable, Sendable {
    /// The levels the simulator's `/usr/bin/log stream` actually
    /// accepts — `--level default | info | debug`. Each is
    /// "include events at-or-above this severity", so `default`
    /// already covers default / error / fault. macOS's host `log`
    /// binary takes additional values (`notice`, `error`, `fault`),
    /// but the iOS simulator runtime ships a slimmer interface
    /// and rejects them.
    public enum Level: String, Equatable, Sendable, CaseIterable {
        case `default`, info, debug

        /// Case-insensitive match against the wire / CLI string.
        public init?(wire raw: String) {
            guard !raw.isEmpty else { return nil }
            self.init(rawValue: raw.lowercased())
        }
    }

    public enum Style: String, Equatable, Sendable, CaseIterable {
        case `default`, compact, json, syslog, ndjson

        public init?(wire raw: String) {
            guard !raw.isEmpty else { return nil }
            self.init(rawValue: raw.lowercased())
        }
    }

    public let level: Level
    public let style: Style
    /// Raw `NSPredicate` — passed to `log stream --predicate` verbatim.
    /// `nil` and `""` are equivalent (no predicate clause).
    public let predicate: String?
    /// Convenience: filter to a specific process by bundle / image
    /// name. Translated into `process == "<id>"` and ANDed with
    /// `predicate` when both are given.
    public let bundleId: String?

    public init(
        level: Level = .info,
        style: Style = .default,
        predicate: String? = nil,
        bundleId: String? = nil
    ) {
        self.level = level
        self.style = style
        self.predicate = predicate?.isEmpty == true ? nil : predicate
        self.bundleId  = bundleId?.isEmpty  == true ? nil : bundleId
    }

    /// argv passed to `SimDevice.spawn(/usr/bin/log, …)`. The
    /// `arguments` dict CoreSimulator hands to `posix_spawn`
    /// replaces argv *entirely* — including argv[0] — so we
    /// prepend the program name explicitly. Without it the
    /// simulator's `log` binary parses our `stream` subcommand
    /// as its own argv[0] and the rest of the flags fail.
    public var argv: [String] {
        var out: [String] = ["log", "stream", "--level", level.rawValue, "--style", style.rawValue]
        if let combined = combinedPredicate {
            out.append("--predicate")
            out.append(combined)
        }
        return out
    }

    private var combinedPredicate: String? {
        switch (predicate, bundleId) {
        case (nil, nil):                return nil
        case (let p?, nil):             return p
        case (nil, let id?):            return Self.processPredicate(id)
        case (let p?, let id?):         return "(\(p)) AND (\(Self.processPredicate(id)))"
        }
    }

    private static func processPredicate(_ bundleId: String) -> String {
        // Quote-escape the bundle id so a value like `com.acme."weird"`
        // doesn't break the predicate clause.
        let escaped = bundleId.replacingOccurrences(of: "\"", with: "\\\"")
        return "process == \"\(escaped)\""
    }
}
