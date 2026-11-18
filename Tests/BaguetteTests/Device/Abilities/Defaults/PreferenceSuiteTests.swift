import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// Where an app's preferences live on a simulator. simctl reports the
/// container (`get_app_container`), so nothing here guesses a path —
/// the suite only names *which* container and *which* plist inside it.
@Suite("PreferenceSuite")
struct PreferenceSuiteTests {

    @Test func `should look for standard defaults in the app's data container`() throws {
        let suite = try PreferenceSuite(bundleID: "com.example.app")
        #expect(suite.containerArguments(udid: "U")
            == ["simctl", "get_app_container", "U", "com.example.app", "data"])
    }

    @Test func `should look for preferences inside the device's custom device set when it lives in one`() throws {
        let suite = try PreferenceSuite(bundleID: "com.example.app")
        #expect(suite.containerArguments(udid: "U", deviceSetPath: "/custom set")
            == ["simctl", "--set", "/custom set", "get_app_container", "U", "com.example.app", "data"])
    }

    @Test func `should look for a suite among the app's App Group containers`() throws {
        // simctl's own `get_app_container … <group id>` exits 117 even for
        // a group the app has (Xcode 27), so the suite is found in the
        // `groups` listing instead.
        let suite = try PreferenceSuite(bundleID: "com.example.app", name: "group.com.example.shared")
        #expect(suite.containerArguments(udid: "U")
            == ["simctl", "get_app_container", "U", "com.example.app", "groups"])
    }

    @Test func `should look for a suite that is not an App Group in the app's own data container`() throws {
        // `UserDefaults(suiteName: "com.example.debug")` — App Group ids
        // always start with `group.`, so anything else is the app's own.
        let suite = try PreferenceSuite(bundleID: "com.example.app", name: "com.example.debug")
        #expect(suite.containerArguments(udid: "U")
            == ["simctl", "get_app_container", "U", "com.example.app", "data"])
        #expect(suite.plistPath(inContainerOutput: "/data/Application/A1\n")
            == "/data/Application/A1/Library/Preferences/com.example.debug.plist")
    }

    @Test func `should keep standard defaults in the plist named for the app`() throws {
        let suite = try PreferenceSuite(bundleID: "com.example.app")
        #expect(suite.plistPath(inContainerOutput: "/data/Application/A1\n")
            == "/data/Application/A1/Library/Preferences/com.example.app.plist")
    }

    @Test func `should keep a suite in the plist named for the suite inside its group's container`() throws {
        let suite = try PreferenceSuite(bundleID: "com.example.app", name: "group.x")
        #expect(suite.plistPath(inContainerOutput: """
        group.x.other\t/Shared/AppGroup/G0
        group.x\t/Shared/AppGroup/G1 with space
        """) == "/Shared/AppGroup/G1 with space/Library/Preferences/group.x.plist")
    }

    @Test func `should find no plist for a suite the app's groups don't include`() throws {
        let suite = try PreferenceSuite(bundleID: "com.example.app", name: "group.x")
        #expect(suite.plistPath(inContainerOutput: "group.y\t/Shared/AppGroup/G1\n") == nil)
        #expect(suite.plistPath(inContainerOutput: "") == nil)
    }

    @Test func `should find no plist when simctl names no container`() throws {
        #expect(try PreferenceSuite(bundleID: "com.example.app").plistPath(inContainerOutput: "\n") == nil)
    }

    @Test func `should list the App Groups an app has, in order`() {
        #expect(PreferenceSuite.groups(inListing: """
        group.b\t/Shared/AppGroup/G2
        group.a\t/Shared/AppGroup/G1 with space

        """) == ["group.a", "group.b"])
        #expect(PreferenceSuite.groups(inListing: "") == [])
    }

    @Test func `should refuse an identifier that could leave the container`() {
        for (bundleID, suite) in [
            ("", nil), ("../etc", nil), ("com/x", nil), ("-help", nil),
            ("com.x", ""), ("com.x", "../../x"), ("com.x", "group/x"),
        ] as [(String, String?)] {
            #expect(throws: PreferenceSuiteError.self) {
                try PreferenceSuite(bundleID: bundleID, name: suite)
            }
        }
    }
}

/// A suite as `defaults export` printed it — the persisted values, each
/// typed, and nothing that would blur an absent key into a stored one.
@Suite("Preferences")
struct PreferencesTests {

    private static func export(_ body: String) -> Data {
        Data(("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        \(body)
        </plist>
        """).utf8)
    }

    @Test func `should read every stored preference with its type from a defaults export`() {
        let preferences = Preferences(export: Self.export(
            "<dict><key>onboardingComplete</key><false/><key>launches</key><integer>3</integer></dict>"
        ))
        #expect(preferences?.values == ["onboardingComplete": .bool(false), "launches": .integer(3)])
    }

    @Test func `should read a suite with nothing stored as no preferences`() {
        #expect(Preferences(export: Self.export("<dict/>"))?.values == [:])
    }

    @Test func `should not read output that is not an exported suite`() {
        #expect(Preferences(export: Data("Invalid device: X".utf8)) == nil)
        #expect(Preferences(export: Self.export("<array/>")) == nil)
    }

    @Test func `should report a stored false as present`() {
        let preferences = Preferences(values: ["seen": .bool(false)])
        #expect(preferences.json(forKey: "seen") as NSDictionary
            == ["key": "seen", "present": true, "type": "bool", "value": false] as NSDictionary)
    }

    @Test func `should report a key that was never stored as absent`() {
        #expect(Preferences(values: [:]).json(forKey: "seen") as NSDictionary
            == ["key": "seen", "present": false] as NSDictionary)
    }

    @Test func `should report the whole suite with every value typed`() {
        let preferences = Preferences(values: ["n": .integer(1)])
        #expect(preferences.json as NSDictionary
            == ["n": ["type": "int", "value": 1]] as NSDictionary)
    }

    @Test func `should report a read with the app and suite it came from`() throws {
        let suite = try PreferenceSuite(bundleID: "com.x", name: "group.x")
        #expect(Preferences(values: ["n": .bool(true)]).json(in: suite) as NSDictionary == [
            "bundleId": "com.x", "suite": "group.x",
            "values": ["n": ["type": "bool", "value": true]],
        ] as NSDictionary)
        #expect(Preferences(values: [:]).json(in: try PreferenceSuite(bundleID: "com.x")) as NSDictionary
            == ["bundleId": "com.x", "values": [:] as [String: Any]] as NSDictionary)
    }

    @Test func `should keep only the keys asked for`() {
        let preferences = Preferences(values: ["a": .integer(1), "b": .integer(2)])
        #expect(preferences.only(["b", "missing"]).values == ["b": .integer(2)])
    }

    @Test func `should import what an export printed`() throws {
        let export = Data(#"{"bundleId":"com.x","values":{"seen":{"type":"bool","value":false}}}"#.utf8)
        #expect(try Preferences(importing: export).values == ["seen": .bool(false)])
    }

    @Test func `should import a bare map of typed values`() throws {
        let map = Data(#"{"n":{"type":"float","value":3}}"#.utf8)
        #expect(try Preferences(importing: map).values == ["n": .real(3)])
    }

    @Test func `should refuse an import whose value is not typed, naming its key`() {
        #expect(throws: PreferencesImportError.untyped(key: "seen")) {
            try Preferences(importing: Data(#"{"values":{"seen":false}}"#.utf8))
        }
    }

    @Test func `should refuse an import that is not a JSON object`() {
        #expect(throws: PreferencesImportError.notAnObject) {
            try Preferences(importing: Data("[1]".utf8))
        }
    }

    @Test func `should carry a collection's plist text for an editor when asked`() throws {
        let preferences = Preferences(values: ["tags": .array([.integer(1)]), "n": .integer(1)])
        let json = preferences.json(in: try PreferenceSuite(bundleID: "com.x"), plist: true)
        #expect(json as NSDictionary == [
            "bundleId": "com.x",
            "values": [
                "tags": ["type": "array", "value": [["type": "int", "value": 1]],
                         "plist": "<array><integer>1</integer></array>"],
                "n": ["type": "int", "value": 1],
            ],
        ] as NSDictionary)
    }
}
