import Foundation

/// The persisted preferences of one suite, as `defaults export` printed
/// them — every value typed. Registered defaults (`register(defaults:)`)
/// live only in the app's memory and never appear here.
public struct Preferences: Equatable, Sendable {
    public let values: [String: PreferenceValue]

    public init(values: [String: PreferenceValue]) {
        self.values = values
    }

    /// Read `defaults export <domain> -` output. `nil` when it isn't a
    /// plist dictionary, so garbage on stdout is an error rather than an
    /// empty suite. One with nothing stored exports `<dict/>` and
    /// reads as no values.
    public init?(export data: Data) {
        guard let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ),
              plist is [String: Any],
              case .dictionary(let values)? = PreferenceValue(plist: plist)
        else { return nil }
        self.values = values
    }

    /// What an export file holds — the JSON a read reports (`{"values":
    /// {…}}`) or just its typed map — read back so it can be imported.
    /// Throws naming the first key whose value isn't typed, so a
    /// hand-edited file says where it went wrong.
    public init(importing data: Data) throws {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw PreferencesImportError.notAnObject
        }
        let map = object["values"] as? [String: Any] ?? object
        var values: [String: PreferenceValue] = [:]
        for key in map.keys.sorted() {
            do {
                values[key] = try PreferenceValue(json: map[key]!)
            } catch {
                throw PreferencesImportError.untyped(key: key)
            }
        }
        self.values = values
    }

    /// Just `keys` — for exporting part of a suite. A key that isn't
    /// stored is simply not in the result.
    public func only(_ keys: [String]) -> Preferences {
        Preferences(values: values.filter { keys.contains($0.key) })
    }

    /// Every stored value, keyed, each in `PreferenceValue.json`'s typed
    /// shape.
    public var json: [String: Any] {
        values.mapValues(\.json)
    }

    /// The whole suite as a read answers it — which app and suite it
    /// came from, then every value typed. `suite` is omitted for an
    /// app's standard defaults.
    ///
    /// With `plist`, each top-level array or dictionary also carries its
    /// `"plist"` fragment, so an editor can show it as editable text and
    /// post it back as `type: plist` without knowing plist itself.
    public func json(in suite: PreferenceSuite, plist: Bool = false) -> [String: Any] {
        let values = plist ? values.mapValues { value -> [String: Any] in
            switch value {
            case .array, .dictionary: return value.json.merging(["plist": value.xmlFragment]) { _, new in new }
            default: return value.json
            }
        } : json
        var envelope: [String: Any] = ["bundleId": suite.bundleID, "values": values]
        if let name = suite.name { envelope["suite"] = name }
        return envelope
    }

    /// One key, with `present` telling a key that was never stored apart
    /// from one stored as `false`, `0` or `""`.
    public func json(forKey key: String) -> [String: Any] {
        guard let value = values[key] else { return ["key": key, "present": false] }
        return value.json.merging(["key": key, "present": true]) { _, new in new }
    }
}

public enum PreferencesImportError: Error, Equatable, CustomStringConvertible {
    case notAnObject
    case untyped(key: String)

    public var description: String {
        switch self {
        case .notAnObject:
            return "an import must be a JSON object: a `defaults export` or a map of typed values"
        case .untyped(let key):
            return #"\#(key) is not a {"type": …, "value": …} preference value"#
        }
    }
}
