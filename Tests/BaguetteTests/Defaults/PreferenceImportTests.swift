import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDevice

/// Restoring a saved set of preferences in one go — the repeatable test
/// setup an export makes possible. A relaunch wraps the whole batch, not
/// each key, so the app starts once, from all of it.
@Suite("PreferenceImport")
struct PreferenceImportTests {

    final class Journal: @unchecked Sendable {
        var steps: [String] = []
    }

    private static let suite = try! PreferenceSuite(bundleID: "com.example.app")

    private func host(
        failingKey: String? = nil, lookups: PreferenceLookups? = nil
    ) -> (MockDefaults, MockApps, Journal) {
        let defaults = MockDefaults()
        let apps = MockApps()
        let journal = Journal()
        given(defaults).lookups(of: .any).willReturn(lookups)
        given(defaults).write(.any, forKey: .any, in: .any).willProduce { value, key, _ in
            if key == failingKey { throw DefaultsError.simctlFailed(status: 1) }
            journal.steps.append("write \(key)=\(value.xmlFragment)")
        }
        given(apps).terminate(bundleID: .any).willProduce { journal.steps.append("terminate \($0)") }
        given(apps).launch(bundleID: .any).willProduce { journal.steps.append("launch \($0)") }
        return (defaults, apps, journal)
    }

    private static let saved = Preferences(values: ["b": .integer(2), "a": .bool(true)])

    @Test func `should write every saved value in key order and leave the app alone`() async throws {
        let (defaults, apps, journal) = host()
        let restore = PreferenceImport(suite: Self.suite, preferences: Self.saved)

        #expect(try await restore.apply(on: defaults, apps: apps) == PreferenceImport.Applied(written: 2, relaunched: false))
        #expect(journal.steps == ["write a=<true/>", "write b=<integer>2</integer>"])
    }

    @Test func `should quit the app once before the import and launch it once after when asked to relaunch`() async throws {
        let (defaults, apps, journal) = host()
        let restore = PreferenceImport(suite: Self.suite, preferences: Self.saved, relaunch: .always)

        #expect(try await restore.apply(on: defaults, apps: apps).relaunched)

        #expect(journal.steps == [
            "terminate com.example.app", "write a=<true/>", "write b=<integer>2</integer>",
            "launch com.example.app",
        ])
    }

    @Test func `should stop at the first value that fails and leave the app quit`() async {
        let (defaults, apps, journal) = host(failingKey: "a")
        let restore = PreferenceImport(suite: Self.suite, preferences: Self.saved, relaunch: .always)

        await #expect(throws: DefaultsError.simctlFailed(status: 1)) {
            try await restore.apply(on: defaults, apps: apps)
        }
        #expect(journal.steps == ["terminate com.example.app"])
    }

    @Test func `should import settings the running app watches without relaunching it`() async throws {
        let (defaults, apps, journal) = host(lookups: PreferenceLookups(pid: 1, all: [
            PreferenceLookup(key: "a", type: .bool, live: true),
            PreferenceLookup(key: "b", type: .int, live: true),
        ]))
        let restore = PreferenceImport(suite: Self.suite, preferences: Self.saved, relaunch: .whenNeeded)

        #expect(try await restore.apply(on: defaults, apps: apps).relaunched == false)
        #expect(journal.steps == ["write a=<true/>", "write b=<integer>2</integer>"])
    }

    @Test func `should relaunch once around an import holding any setting the app read only once`() async throws {
        let (defaults, apps, journal) = host(lookups: PreferenceLookups(pid: 1, all: [
            PreferenceLookup(key: "a", type: .bool, live: true),
            PreferenceLookup(key: "b", type: .int),
        ]))
        let restore = PreferenceImport(suite: Self.suite, preferences: Self.saved, relaunch: .whenNeeded)

        #expect(try await restore.apply(on: defaults, apps: apps).relaunched)
        #expect(journal.steps.first == "terminate com.example.app")
        #expect(journal.steps.last == "launch com.example.app")
    }
}
