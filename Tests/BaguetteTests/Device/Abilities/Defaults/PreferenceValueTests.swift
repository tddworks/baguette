import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// A stored preference is a typed plist value. The two directions that
/// matter are **in** (what the user typed on the CLI / sent over HTTP,
/// or what `defaults export` printed) and **out** (the XML fragment
/// `defaults write` takes, and the typed JSON a caller reads back).
@Suite("PreferenceValue")
struct PreferenceValueTests {

    // MARK: - typed input

    @Test func `should read a boolean typed as false as a stored false`() throws {
        #expect(try PreferenceValue.parse(type: .bool, value: "false") == .bool(false))
    }

    @Test func `should accept yes, no, 1 and 0 as booleans`() throws {
        #expect(try PreferenceValue.parse(type: .bool, value: "YES") == .bool(true))
        #expect(try PreferenceValue.parse(type: .bool, value: "no") == .bool(false))
        #expect(try PreferenceValue.parse(type: .bool, value: "1") == .bool(true))
        #expect(try PreferenceValue.parse(type: .bool, value: "0") == .bool(false))
    }

    @Test func `should keep an integer an integer`() throws {
        #expect(try PreferenceValue.parse(type: .int, value: "-42") == .integer(-42))
    }

    @Test func `should keep a whole-number float a real`() throws {
        #expect(try PreferenceValue.parse(type: .float, value: "1") == .real(1))
    }

    @Test func `should keep a string verbatim even when it looks like another type`() throws {
        #expect(try PreferenceValue.parse(type: .string, value: "true") == .string("true"))
        #expect(try PreferenceValue.parse(type: .string, value: "") == .string(""))
    }

    @Test func `should read a date typed in ISO 8601`() throws {
        #expect(try PreferenceValue.parse(type: .date, value: "2026-01-02T03:04:05Z")
            == .date(Date(timeIntervalSince1970: 1_767_323_045)))
    }

    @Test func `should read data typed as base64`() throws {
        #expect(try PreferenceValue.parse(type: .data, value: "AAEC") == .data(Data([0, 1, 2])))
    }

    @Test func `should read an array typed as a plist fragment with every element typed`() throws {
        #expect(try PreferenceValue.parse(
            type: .plist, value: "<array><integer>1</integer><real>1</real><string>x</string></array>"
        ) == .array([.integer(1), .real(1), .string("x")]))
    }

    @Test func `should read a dictionary typed as a plist fragment`() throws {
        #expect(try PreferenceValue.parse(
            type: .plist, value: "<dict><key>seen</key><true/></dict>"
        ) == .dictionary(["seen": .bool(true)]))
    }

    @Test func `should refuse a value that is not of its type`() {
        for (type, value) in [
            (PreferenceType.bool, "maybe"), (.int, "1.5"), (.float, "abc"),
            (.float, "nan"), (.date, "yesterday"), (.data, "%%%"), (.plist, "<array>"),
        ] {
            #expect(throws: PreferenceValueError.notA(type, value)) {
                try PreferenceValue.parse(type: type, value: value)
            }
        }
    }

    @Test func `should name every type on the wire`() {
        #expect(PreferenceType.allCases.map(\.wireName)
            == ["bool", "int", "float", "string", "date", "data", "plist"])
        #expect(PreferenceType(wireName: "float") == .float)
        #expect(PreferenceType(wireName: "double") == nil)
    }

    // MARK: - what defaults write takes

    @Test func `should write every scalar as the plist element of its type`() {
        #expect(PreferenceValue.bool(false).xmlFragment == "<false/>")
        #expect(PreferenceValue.bool(true).xmlFragment == "<true/>")
        #expect(PreferenceValue.integer(7).xmlFragment == "<integer>7</integer>")
        #expect(PreferenceValue.real(1).xmlFragment == "<real>1.0</real>")
        #expect(PreferenceValue.date(Date(timeIntervalSince1970: 1_767_323_045)).xmlFragment
            == "<date>2026-01-02T03:04:05Z</date>")
        #expect(PreferenceValue.data(Data([0, 1, 2])).xmlFragment == "<data>AAEC</data>")
    }

    @Test func `should escape a string so markup in it stays text`() {
        #expect(PreferenceValue.string("<true/> & co").xmlFragment
            == "<string>&lt;true/&gt; &amp; co</string>")
    }

    @Test func `should write a dictionary with its keys in a stable order`() {
        #expect(PreferenceValue.dictionary(["b": .integer(1), "a&": .array([.bool(true)])]).xmlFragment
            == "<dict><key>a&amp;</key><array><true/></array><key>b</key><integer>1</integer></dict>")
    }

    @Test func `should round-trip a fragment it wrote`() throws {
        let value = PreferenceValue.dictionary([
            "n": .real(0.25), "s": .string("<x>"), "l": .array([.integer(3), .data(Data([9]))]),
        ])
        #expect(try PreferenceValue.parse(type: .plist, value: value.xmlFragment) == value)
    }

    // MARK: - what a caller reads back

    @Test func `should report a value with its type for a caller`() {
        #expect(PreferenceValue.bool(false).json as NSDictionary
            == ["type": "bool", "value": false] as NSDictionary)
        #expect(PreferenceValue.real(2).json as NSDictionary
            == ["type": "float", "value": 2.0] as NSDictionary)
        #expect(PreferenceValue.date(Date(timeIntervalSince1970: 0)).json as NSDictionary
            == ["type": "date", "value": "1970-01-01T00:00:00Z"] as NSDictionary)
        #expect(PreferenceValue.data(Data([0, 1, 2])).json as NSDictionary
            == ["type": "data", "value": "AAEC"] as NSDictionary)
    }

    @Test func `should report a collection with every element typed`() {
        let json = PreferenceValue.dictionary(["l": .array([.integer(1)])]).json as NSDictionary
        #expect(json == [
            "type": "dict",
            "value": ["l": ["type": "array", "value": [["type": "int", "value": 1]]]],
        ] as NSDictionary)
    }

    // MARK: - what defaults export printed

    @Test func `should tell a stored boolean from a stored number`() {
        #expect(PreferenceValue(plist: NSNumber(value: true)) == .bool(true))
        #expect(PreferenceValue(plist: NSNumber(value: 1)) == .integer(1))
        #expect(PreferenceValue(plist: NSNumber(value: 1.0)) == .real(1))
    }

    // MARK: - what an import reads

    @Test func `should read back every value it reported`() throws {
        let values: [PreferenceValue] = [
            .bool(false), .integer(-3), .real(0.25), .real(2), .string(""),
            .date(Date(timeIntervalSince1970: 1_767_323_045)), .data(Data([0, 1, 2])),
            .array([.integer(1), .string("x")]), .dictionary(["a": .dictionary(["b": .bool(true)])]),
        ]
        for value in values {
            let reported = try JSONSerialization.jsonObject(
                with: JSONSerialization.data(withJSONObject: value.json)
            )
            #expect(try PreferenceValue(json: reported) == value)
        }
    }

    @Test func `should keep a whole-number float a real when importing`() throws {
        #expect(try PreferenceValue(json: ["type": "float", "value": 1]) == .real(1))
    }

    @Test func `should refuse JSON that is not a typed value`() {
        for json: Any in [
            "false", ["value": false], ["type": "double", "value": 1],
            ["type": "bool", "value": "true"], ["type": "bool", "value": 1],
            ["type": "int", "value": 1.5], ["type": "int", "value": true],
            ["type": "float", "value": false], ["type": "string", "value": 1],
            ["type": "date", "value": "yesterday"], ["type": "data", "value": "%%"],
            ["type": "array", "value": [1]], ["type": "dict", "value": ["a": 1]],
        ] {
            #expect(throws: PreferenceValueError.self) { try PreferenceValue(json: json) }
        }
    }
}
