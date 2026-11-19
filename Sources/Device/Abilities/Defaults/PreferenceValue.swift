import Foundation

/// One stored preference — a typed property-list value, as an app reads
/// it back through `UserDefaults`. The type is the point: an
/// onboarding flag stored as the string `"false"` reads as `true` from
/// `bool(forKey:)`, so a value that loses its type on the way in is a
/// different preference, not the same one spelled differently.
///
/// Two directions, both pure:
///
/// - **in** — `parse(type:value:)` from what a person typed (`--type
///   bool --value false`), and `init?(plist:)` from what `defaults
///   export` printed.
/// - **out** — `xmlFragment`, the plist element `defaults write <domain>
///   <key> <fragment>` stores with its type intact (verified for all
///   eight types against an iOS 27 simulator), and `json`, the typed
///   shape a caller reads back.
public indirect enum PreferenceValue: Equatable, Sendable {
    case bool(Bool)
    case integer(Int)
    case real(Double)
    case string(String)
    case date(Date)
    case data(Data)
    case array([PreferenceValue])
    case dictionary([String: PreferenceValue])

    // MARK: - in

    /// The value a person typed, read as `type`. Throws
    /// `PreferenceValueError.notA` rather than falling back to a string:
    /// `--type int --value 1.5` storing `"1.5"` would be the silent type
    /// change this whole type exists to prevent.
    public static func parse(type: PreferenceType, value: String) throws -> PreferenceValue {
        let parsed: PreferenceValue?
        switch type {
        case .bool:
            switch value.lowercased() {
            case "true", "yes", "1": parsed = .bool(true)
            case "false", "no", "0": parsed = .bool(false)
            default: parsed = nil
            }
        case .int:
            parsed = Int(value).map(PreferenceValue.integer)
        case .float:
            parsed = Double(value).flatMap { $0.isFinite ? .real($0) : nil }
        case .string:
            parsed = .string(value)
        case .date:
            parsed = Self.iso8601.date(from: value).map(PreferenceValue.date)
        case .data:
            parsed = Data(base64Encoded: value).map(PreferenceValue.data)
        case .plist:
            let document = #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0">"#
                + value + "</plist>"
            parsed = (try? PropertyListSerialization.propertyList(
                from: Data(document.utf8), options: [], format: nil
            )).flatMap(PreferenceValue.init(plist:))
        }
        guard let parsed else { throw PreferenceValueError.notA(type, value) }
        return parsed
    }

    /// A value as `PropertyListSerialization` hands it over. `nil` for
    /// anything that isn't a plist type.
    ///
    /// Booleans and numbers both arrive as `NSNumber`, so the CF type
    /// decides: a stored `<true/>` must read back as a bool and a stored
    /// `<real>1</real>` as a real, or reading a suite and writing it back
    /// would change it.
    public init?(plist: Any) {
        switch plist {
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .real(number.doubleValue)
            } else {
                self = .integer(number.intValue)
            }
        case let date as Date:
            self = .date(date)
        case let data as Data:
            self = .data(data)
        case let array as [Any]:
            var values: [PreferenceValue] = []
            for element in array {
                guard let value = PreferenceValue(plist: element) else { return nil }
                values.append(value)
            }
            self = .array(values)
        case let dictionary as [String: Any]:
            var values: [String: PreferenceValue] = [:]
            for (key, element) in dictionary {
                guard let value = PreferenceValue(plist: element) else { return nil }
                values[key] = value
            }
            self = .dictionary(values)
        default:
            return nil
        }
    }

    /// A value in the typed shape `json` reports — what an import reads
    /// back from an export. The type tag decides, so `{"type":"float",
    /// "value":1}` is a real even though JSON spells it like an int; a
    /// value whose JSON doesn't fit its tag (`{"type":"bool","value":1}`)
    /// is refused rather than coerced.
    public init(json: Any) throws {
        guard let object = json as? [String: Any],
              let type = object["type"] as? String,
              let raw = object["value"]
        else { throw PreferenceValueError.notTyped }
        let isBool = (raw as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        switch (type, raw) {
        case ("bool", let flag as NSNumber) where isBool:
            self = .bool(flag.boolValue)
        case ("int", let n as NSNumber) where !isBool && !CFNumberIsFloatType(n):
            self = .integer(n.intValue)
        case ("float", let x as NSNumber) where !isBool:
            self = .real(x.doubleValue)
        case ("string", let text as String):
            self = .string(text)
        case ("date", let text as String):
            self = try PreferenceValue.parse(type: .date, value: text)
        case ("data", let text as String):
            self = try PreferenceValue.parse(type: .data, value: text)
        case ("array", let elements as [Any]):
            self = .array(try elements.map(PreferenceValue.init(json:)))
        case ("dict", let entries as [String: Any]):
            self = .dictionary(try entries.mapValues(PreferenceValue.init(json:)))
        default:
            throw PreferenceValueError.notTyped
        }
    }

    // MARK: - out

    /// The plist element `defaults write` stores with its type intact.
    /// Strings and keys are XML-escaped, so a string that *looks* like
    /// markup (`"<true/>"`) stays a string. Dictionary keys are sorted so
    /// the fragment is deterministic.
    public var xmlFragment: String {
        switch self {
        case .bool(let flag): return flag ? "<true/>" : "<false/>"
        case .integer(let n): return "<integer>\(n)</integer>"
        case .real(let x): return "<real>\(x)</real>"
        case .string(let s): return "<string>\(Self.escaped(s))</string>"
        case .date(let d): return "<date>\(Self.iso8601.string(from: d))</date>"
        case .data(let d): return "<data>\(d.base64EncodedString())</data>"
        case .array(let values):
            return "<array>" + values.map(\.xmlFragment).joined() + "</array>"
        case .dictionary(let values):
            return "<dict>" + values.keys.sorted().map {
                "<key>\(Self.escaped($0))</key>" + values[$0]!.xmlFragment
            }.joined() + "</dict>"
        }
    }

    /// `{"type": …, "value": …}` — the type travels with the value so a
    /// caller never has to guess whether `1` was an int or a float.
    /// Dates read as ISO 8601, data as base64, and collections carry
    /// every element in the same typed shape.
    public var json: [String: Any] {
        switch self {
        case .bool(let flag): return ["type": typeName, "value": flag]
        case .integer(let n): return ["type": typeName, "value": n]
        case .real(let x): return ["type": typeName, "value": x]
        case .string(let s): return ["type": typeName, "value": s]
        case .date(let d): return ["type": typeName, "value": Self.iso8601.string(from: d)]
        case .data(let d): return ["type": typeName, "value": d.base64EncodedString()]
        case .array(let values): return ["type": typeName, "value": values.map(\.json)]
        case .dictionary(let values):
            return ["type": typeName, "value": values.mapValues(\.json)]
        }
    }

    /// The type as a caller reads it — `PreferenceType`'s spellings for
    /// scalars, `array` / `dict` for the two collections (which are
    /// *written* through `plist`).
    public var typeName: String {
        switch self {
        case .bool: return "bool"
        case .integer: return "int"
        case .real: return "float"
        case .string: return "string"
        case .date: return "date"
        case .data: return "data"
        case .array: return "array"
        case .dictionary: return "dict"
        }
    }

    // MARK: - helpers

    // `ISO8601DateFormatter` is thread-safe for formatting and parsing.
    nonisolated(unsafe) private static let iso8601 = ISO8601DateFormatter()

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// How a typed value is spelled on the CLI (`--type`) and the HTTP
/// body (`"type"`). Arrays and dictionaries go through `plist`, an XML
/// fragment, because JSON can't tell `1` from `1.0`.
public enum PreferenceType: CaseIterable, Equatable, Sendable {
    case bool, int, float, string, date, data, plist

    public var wireName: String {
        switch self {
        case .bool: return "bool"
        case .int: return "int"
        case .float: return "float"
        case .string: return "string"
        case .date: return "date"
        case .data: return "data"
        case .plist: return "plist"
        }
    }

    public init?(wireName: String) {
        guard let match = Self.allCases.first(where: { $0.wireName == wireName }) else {
            return nil
        }
        self = match
    }
}

public enum PreferenceValueError: Error, Equatable, CustomStringConvertible {
    /// The typed text isn't a value of the named type.
    case notA(PreferenceType, String)
    /// JSON that isn't `{"type": …, "value": …}` with a value of that type.
    case notTyped

    public var description: String {
        switch self {
        case .notA(let type, let value):
            return "\"\(value)\" is not a valid \(type.wireName)"
        case .notTyped:
            return #"not a {"type": …, "value": …} preference value"#
        }
    }
}
