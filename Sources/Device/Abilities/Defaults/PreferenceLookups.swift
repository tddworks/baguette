import Foundation

/// One preference a running app looked up: the key, the suite it asked
/// (`nil` for its standard defaults), the type its getter asked for, and
/// the fallback it registered with `register(defaults:)`, if any.
///
/// This is how a setting nobody has stored yet becomes visible. Its key
/// lives only in the app's code until the app reads it, and an
/// `@AppStorage` default (`= .system`) never leaves Swift, so the most
/// the app can tell about an unset key is that it asked, and as what.
public struct PreferenceLookup: Equatable, Sendable {
    public let key: String
    public let suite: String?
    /// `nil` when the app only ever asked untyped (`object(forKey:)`).
    public let type: PreferenceType?
    public let registered: PreferenceValue?
    /// Whether the running app updates the moment this key changes: SwiftUI
    /// observes it (`@AppStorage`), and cfprefsd tells the app when a write
    /// lands. A key the app only read once — into a property, at startup —
    /// is seen only after a relaunch.
    public let live: Bool

    public init(
        key: String, suite: String? = nil, type: PreferenceType?,
        registered: PreferenceValue? = nil, live: Bool = false
    ) {
        self.key = key
        self.suite = suite
        self.type = type
        self.registered = registered
        self.live = live
    }

    /// `{"key", "type"?, "registered"?}` — `type` is left out when the
    /// app's getter didn't say, rather than guessed.
    public var json: [String: Any] {
        var json: [String: Any] = ["key": key]
        if let type { json["type"] = type.wireName }
        if let registered { json["registered"] = registered.json }
        return json
    }
}

/// What a running app answers when asked which preferences it has looked
/// up — every key its own code or SwiftUI read, once, typed.
///
/// The injected `DefaultsLookups.dylib` keeps the answer in the app's
/// memory and writes it as a plist whenever it grows, carrying the app's
/// `pid` so a caller can tell the answer of the app running now from one
/// left behind by an app that has quit.
public struct PreferenceLookups: Equatable, Sendable {
    public let pid: Int32
    /// Sorted by key, then suite.
    public let all: [PreferenceLookup]

    public init(pid: Int32, all: [PreferenceLookup]) {
        self.pid = pid
        self.all = all
    }

    /// Read the answer plist. `nil` when it isn't one — a half-written or
    /// foreign file answers nothing rather than something wrong.
    ///
    /// The plist records facts, not verdicts — each getter called, by whom
    /// (`app` or `swiftui`), and which keys SwiftUI observes — and the
    /// rules live here:
    ///
    /// - a key asked for untyped and then as a string *is* a string, so the
    ///   typed reading wins whatever order the calls came in;
    /// - SwiftUI's read is the app's (`@AppStorage`) only for a key SwiftUI
    ///   also observes. It reads its own flags through the same getters
    ///   but never watches them (measured, iOS 27.0).
    public init?(answer data: Data) {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = plist as? [String: Any],
              let pid = (root["pid"] as? NSNumber)?.int32Value
        else { return nil }

        struct Slot: Hashable { let key: String; let suite: String? }
        var types: [Slot: PreferenceType] = [:]
        var registered: [Slot: PreferenceValue] = [:]
        var seen: Set<Slot> = []

        let watchedBySwiftUI = Set((root["observed"] as? [[String: Any]] ?? []).compactMap { entry in
            (entry["key"] as? String).map { Slot(key: $0, suite: entry["suite"] as? String) }
        })
        for entry in root["lookups"] as? [[String: Any]] ?? [] {
            guard let key = entry["key"] as? String else { continue }
            let slot = Slot(key: key, suite: entry["suite"] as? String)
            // SwiftUI reads for `@AppStorage` and for its own flags through
            // the same getters; only `@AppStorage` also observes its key.
            if entry["by"] as? String == "swiftui", !watchedBySwiftUI.contains(slot) { continue }
            seen.insert(slot)
            if let type = (entry["getter"] as? String).flatMap(Self.type(ofGetter:)) {
                types[slot] = type
            }
        }
        for entry in root["registered"] as? [[String: Any]] ?? [] {
            guard let key = entry["key"] as? String,
                  let value = entry["value"].flatMap(PreferenceValue.init(plist:))
            else { continue }
            let slot = Slot(key: key, suite: entry["suite"] as? String)
            seen.insert(slot)
            registered[slot] = value
            // A registered fallback's own type stands in for a getter the
            // app hasn't called yet.
            if types[slot] == nil { types[slot] = PreferenceType(wireName: value.typeName) ?? .plist }
        }

        self.pid = pid
        self.all = seen
            .map {
                PreferenceLookup(key: $0.key, suite: $0.suite, type: types[$0],
                                 registered: registered[$0], live: watchedBySwiftUI.contains($0))
            }
            .sorted { ($0.key, $0.suite ?? "") < ($1.key, $1.suite ?? "") }
    }

    /// The keys the app looks up in `suite` that nothing has stored there —
    /// the settings still on the app's own default.
    public func unset(in stored: Preferences, suite: PreferenceSuite) -> [PreferenceLookup] {
        all.filter { $0.suite == suite.name && stored.values[$0.key] == nil }
            .sorted { $0.key < $1.key }
    }

    /// Whether the running app updates at once when `key` in `suite`
    /// changes. A key it never read, or read only once, is not live.
    public func isLive(_ key: String, in suite: PreferenceSuite) -> Bool {
        all.contains { $0.key == key && $0.suite == suite.name && $0.live }
    }

    /// What a suite read reports about the running app: `answered`, the
    /// keys it looks up that `stored` lacks, and the keys it updates on at
    /// once (`live`, stored or not). `nil` lookups — no running app could
    /// answer — report `answered: false`, so a caller can tell "nothing is
    /// unset" from "the app can't say".
    public static func json(_ lookups: PreferenceLookups?, unsetIn stored: Preferences, suite: PreferenceSuite) -> [String: Any] {
        guard let lookups else { return ["answered": false] }
        return [
            "answered": true,
            "unset": lookups.unset(in: stored, suite: suite).map(\.json),
            "live": lookups.all.filter { $0.suite == suite.name && $0.live }.map(\.key),
        ]
    }

    /// The `NSUserDefaults` getter the app called, as the type it asked
    /// for. `object(forKey:)` and `url(forKey:)` say nothing about the
    /// stored type, so they leave it open.
    private static func type(ofGetter getter: String) -> PreferenceType? {
        switch getter {
        case "string": return .string
        case "bool": return .bool
        case "integer": return .int
        case "double", "float": return .float
        case "data": return .data
        case "array", "dictionary", "stringArray": return .plist
        default: return nil
        }
    }
}
