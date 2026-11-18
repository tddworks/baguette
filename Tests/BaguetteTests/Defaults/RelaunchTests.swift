import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDevice

/// Whether an edit needs the app relaunched to be seen. A running app that
/// watches a key (`@AppStorage`) updates the moment cfprefsd reports the
/// write; one that read it once at startup sees it only after a relaunch.
@Suite("Relaunch")
struct RelaunchTests {

    private static let suite = try! PreferenceSuite(bundleID: "com.onegai.unveil")
    private static let running = PreferenceLookups(pid: 1, all: [
        PreferenceLookup(key: "unveil-ios-glass", type: .string, live: true),
        PreferenceLookup(key: "desk", type: .string),
    ])

    @Test func `should not relaunch for a key the running app watches when relaunching only as needed`() {
        #expect(Relaunch.whenNeeded.needed(for: ["unveil-ios-glass"], in: Self.suite, lookups: Self.running) == false)
    }

    @Test func `should relaunch for a key the running app read only once when relaunching only as needed`() {
        #expect(Relaunch.whenNeeded.needed(for: ["desk"], in: Self.suite, lookups: Self.running))
        #expect(Relaunch.whenNeeded.needed(for: ["unveil-ios-glass", "desk"], in: Self.suite, lookups: Self.running))
    }

    @Test func `should relaunch when no running app can say how it reads the key`() {
        #expect(Relaunch.whenNeeded.needed(for: ["unveil-ios-glass"], in: Self.suite, lookups: nil))
    }

    @Test func `should relaunch always or never when told to whatever the app reads`() {
        #expect(Relaunch.always.needed(for: ["unveil-ios-glass"], in: Self.suite, lookups: Self.running))
        #expect(Relaunch.never.needed(for: ["desk"], in: Self.suite, lookups: nil) == false)
    }

    @Test func `should read how to relaunch from the wire`() {
        #expect(Relaunch(wire: true) == .always)
        #expect(Relaunch(wire: false) == .never)
        #expect(Relaunch(wire: nil) == .never)
        #expect(Relaunch(wire: "whenNeeded") == .whenNeeded)
        #expect(Relaunch(wire: "1") == .always)
        #expect(Relaunch(wire: "sometimes") == nil)
    }
}
