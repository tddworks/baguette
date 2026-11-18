import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// What a running app answers when asked which preferences it has looked
/// up — the keys its own code (or SwiftUI's `@AppStorage`) read, each with
/// the type its getter asked for and any fallback it registered.
///
/// The answer is a plist the injected `DefaultsLookups.dylib` writes, so a
/// registered fallback keeps its exact type. See
/// `docs/features/defaults/design.md`.
@Suite("PreferenceLookups")
struct PreferenceLookupsTests {

    private func answer(_ plist: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    // MARK: - reading the answer

    @Test func `should read the keys a running app looked up with the type each getter asked for`() throws {
        let lookups = try #require(PreferenceLookups(answer: try answer([
            "pid": 42,
            "lookups": [
                ["key": "desk", "getter": "string"],
                ["key": "shelf.preview", "getter": "bool"],
                ["key": "launches", "getter": "integer"],
                ["key": "zoom", "getter": "double"],
                ["key": "recent", "getter": "array"],
            ],
        ])))
        #expect(lookups.pid == 42)
        #expect(lookups.all == [
            PreferenceLookup(key: "desk", type: .string),
            PreferenceLookup(key: "launches", type: .int),
            PreferenceLookup(key: "recent", type: .plist),
            PreferenceLookup(key: "shelf.preview", type: .bool),
            PreferenceLookup(key: "zoom", type: .float),
        ])
    }

    @Test func `should leave a key's type open when the app only asked for it untyped`() throws {
        let lookups = try #require(PreferenceLookups(answer: try answer([
            "pid": 1, "lookups": [["key": "token", "getter": "object"]],
        ])))
        #expect(lookups.all == [PreferenceLookup(key: "token", type: nil)])
    }

    @Test func `should take the typed reading when the app asked for a key both untyped and typed`() throws {
        let lookups = try #require(PreferenceLookups(answer: try answer([
            "pid": 1,
            "lookups": [
                ["key": "unveil-ios-appearance", "getter": "object"],
                ["key": "unveil-ios-appearance", "getter": "string"],
                ["key": "unveil-ios-appearance", "getter": "object"],
            ],
        ])))
        #expect(lookups.all == [PreferenceLookup(key: "unveil-ios-appearance", type: .string)])
    }

    @Test func `should keep the fallback an app registered with its type`() throws {
        let lookups = try #require(PreferenceLookups(answer: try answer([
            "pid": 1,
            "lookups": [["key": "volume", "getter": "double"]],
            "registered": [
                ["key": "volume", "value": 0.5],
                ["key": "onboarded", "value": false],
            ],
        ])))
        #expect(lookups.all == [
            PreferenceLookup(key: "onboarded", type: .bool, registered: .bool(false)),
            PreferenceLookup(key: "volume", type: .float, registered: .real(0.5)),
        ])
    }

    @Test func `should tell a key in the app's standard defaults from the same key in a suite`() throws {
        let lookups = try #require(PreferenceLookups(answer: try answer([
            "pid": 1,
            "lookups": [
                ["key": "theme", "getter": "string"],
                ["key": "theme", "suite": "group.com.example", "getter": "bool"],
            ],
        ])))
        #expect(lookups.all == [
            PreferenceLookup(key: "theme", type: .string),
            PreferenceLookup(key: "theme", suite: "group.com.example", type: .bool),
        ])
    }

    @Test func `should count a key SwiftUI read for the app when SwiftUI also watches it`() throws {
        // `@AppStorage` both reads its key and observes it for changes.
        let lookups = try #require(PreferenceLookups(answer: try answer([
            "pid": 1,
            "lookups": [["key": "unveil-ios-glass", "getter": "string", "by": "swiftui"]],
            "observed": [["key": "unveil-ios-glass"]],
        ])))
        #expect(lookups.all == [PreferenceLookup(key: "unveil-ios-glass", type: .string, live: true)])
    }

    @Test func `should not count SwiftUI reading its own flags when it does not watch them`() throws {
        // Measured on iOS 27.0: SwiftUI reads internal flags through the
        // same getters, but never observes them.
        let lookups = try #require(PreferenceLookups(answer: try answer([
            "pid": 1,
            "lookups": [
                ["key": "UseSetNeedsLayoutForUpdates", "getter": "object", "by": "swiftui"],
                ["key": "desk", "getter": "string", "by": "app"],
            ],
            "observed": [],
        ])))
        #expect(lookups.all == [PreferenceLookup(key: "desk", type: .string)])
    }

    @Test func `should not answer when the app's answer is not a lookups plist`() {
        #expect(PreferenceLookups(answer: Data("<plist><dict><key>pid".utf8)) == nil)
        #expect(PreferenceLookups(answer: Data("[]".utf8)) == nil)
    }

    // MARK: - live or read once

    @Test func `should know the running app updates at once on a key SwiftUI watches`() throws {
        // `@AppStorage` observes its key, and cfprefsd tells the app when a
        // write lands — measured: Dark → Light with no relaunch, same pid.
        let lookups = try #require(PreferenceLookups(answer: try answer([
            "pid": 1,
            "lookups": [
                ["key": "unveil-ios-glass", "getter": "string", "by": "swiftui"],
                ["key": "desk", "getter": "string", "by": "app"],
            ],
            "observed": [["key": "unveil-ios-glass"]],
        ])))
        let standard = try PreferenceSuite(bundleID: "com.onegai.unveil")
        #expect(lookups.isLive("unveil-ios-glass", in: standard))
        #expect(lookups.all.first { $0.key == "unveil-ios-glass" }?.live == true)
    }

    @Test func `should know the app sees a key it only read once after a relaunch`() throws {
        let lookups = PreferenceLookups(pid: 1, all: [PreferenceLookup(key: "desk", type: .string)])
        let standard = try PreferenceSuite(bundleID: "com.onegai.unveil")
        #expect(lookups.isLive("desk", in: standard) == false)
        #expect(lookups.isLive("never-read", in: standard) == false)
    }

    @Test func `should name the keys the running app updates at once in a suite read`() throws {
        let lookups = PreferenceLookups(pid: 1, all: [
            PreferenceLookup(key: "unveil-ios-glass", type: .string, live: true),
            PreferenceLookup(key: "desk", type: .string),
            PreferenceLookup(key: "theme", suite: "group.x", type: .string, live: true),
        ])
        let standard = try PreferenceSuite(bundleID: "com.onegai.unveil")
        let json = PreferenceLookups.json(lookups, unsetIn: Preferences(values: ["desk": .string("rows")]), suite: standard)
        #expect(json["live"] as? [String] == ["unveil-ios-glass"])
    }

    // MARK: - against what's stored

    @Test func `should list the keys the app looks up that nothing has stored`() throws {
        let lookups = PreferenceLookups(pid: 1, all: [
            PreferenceLookup(key: "unveil-ios-glass", type: .string),
            PreferenceLookup(key: "desk", type: .string),
            PreferenceLookup(key: "shelf.preview", type: .bool),
        ])
        let stored = Preferences(values: ["desk": .string("rows")])
        let standard = try PreferenceSuite(bundleID: "com.onegai.unveil")
        #expect(lookups.unset(in: stored, suite: standard) == [
            PreferenceLookup(key: "shelf.preview", type: .bool),
            PreferenceLookup(key: "unveil-ios-glass", type: .string),
        ])
    }

    @Test func `should list only the unset keys of the suite being edited`() throws {
        let lookups = PreferenceLookups(pid: 1, all: [
            PreferenceLookup(key: "theme", type: .string),
            PreferenceLookup(key: "widgetSize", suite: "group.com.example", type: .int),
        ])
        let group = try PreferenceSuite(bundleID: "com.example", name: "group.com.example")
        #expect(lookups.unset(in: Preferences(values: [:]), suite: group) == [
            PreferenceLookup(key: "widgetSize", suite: "group.com.example", type: .int),
        ])
    }

    // MARK: - typed JSON

    @Test func `should describe an unset key by its type and registered fallback`() {
        let lookup = PreferenceLookup(key: "volume", type: .float, registered: .real(0.5))
        let json = lookup.json
        #expect(json["key"] as? String == "volume")
        #expect(json["type"] as? String == "float")
        #expect((json["registered"] as? [String: Any])?["value"] as? Double == 0.5)
    }

    @Test func `should describe an unset key read untyped with no type`() {
        let json = PreferenceLookup(key: "token", type: nil).json
        #expect(json["type"] == nil)
        #expect(json["registered"] == nil)
    }
}
