import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDevice

/// Handler-level coverage for the defaults routes, driven through the
/// pure dispatch helpers with one device's `MockDefaults` + `MockApps` —
/// no Hummingbird, no booted simulator.
@Suite("Server defaults routes")
struct DefaultsRoutesTests {

    final class Journal: @unchecked Sendable {
        var steps: [String] = []
    }

    private func host(
        stored: [String: PreferenceValue] = ["seen": .bool(false)],
        lookups: PreferenceLookups? = nil,
        failure: DefaultsError? = nil
    ) -> (any Devices, Journal) {
        let defaults = MockDefaults()
        let apps = MockApps()
        let journal = Journal()
        let simulators = routeDevices {
            $0.register(.defaults) { defaults }
            $0.register(.apps) { apps }
        }
        if let failure {
            given(defaults).read(.any).willThrow(failure)
            given(defaults).write(.any, forKey: .any, in: .any).willThrow(failure)
        } else {
            given(defaults).read(.any).willReturn(Preferences(values: stored))
            given(defaults).write(.any, forKey: .any, in: .any).willProduce { value, key, suite in
                journal.steps.append("write \(suite.name ?? suite.bundleID) \(key)=\(value.xmlFragment)")
            }
        }
        given(defaults).delete(key: .any, in: .any).willProduce { key, _ in
            journal.steps.append("delete \(key)")
        }
        given(apps).terminate(bundleID: .any).willProduce { journal.steps.append("terminate \($0)") }
        given(apps).launch(bundleID: .any).willProduce { journal.steps.append("launch \($0)") }
        given(apps).installed().willReturn([
            InstalledApp(bundleIdentifier: "com.apple.mobilesafari", name: "Safari"),
            InstalledApp(bundleIdentifier: "com.x.bench", name: "bench"),
            InstalledApp(bundleIdentifier: "com.x.app", name: "Alpha"),
        ])
        given(defaults).groups(of: .any).willReturn(["group.x", "group.y"])
        given(defaults).lookups(of: .any).willReturn(lookups)
        return (simulators, journal)
    }

    // MARK: - read

    @Test func `should read every preference an app stores`() async {
        let (simulators, _) = host()
        let outcome = await Server.readDefaults(
            udid: "U", query: ["bundleId": "com.x"], devices: simulators
        )
        #expect(outcome == .ok(
            #"{"bundleId":"com.x","lookups":{"answered":false},"values":{"seen":{"type":"bool","value":false}}}"#))
    }

    @Test func `should read the settings the running app looks up that nothing has stored`() async {
        let (simulators, _) = host(lookups: PreferenceLookups(pid: 9, all: [
            PreferenceLookup(key: "seen", type: .bool),
            PreferenceLookup(key: "unveil-ios-glass", type: .string),
            PreferenceLookup(key: "volume", type: .float, registered: .real(0.5)),
        ]))
        let outcome = await Server.readDefaults(
            udid: "U", query: ["bundleId": "com.x"], devices: simulators
        )
        #expect(outcome == .ok(
            #"{"bundleId":"com.x","lookups":{"answered":true,"live":[],"unset":[{"key":"unveil-ios-glass","type":"string"},"#
            + #"{"key":"volume","registered":{"type":"float","value":0.5},"type":"float"}]},"#
            + #""values":{"seen":{"type":"bool","value":false}}}"#))
    }

    @Test func `should read one key as present or absent`() async {
        let (simulators, _) = host()
        #expect(await Server.readDefaults(
            udid: "U", query: ["bundleId": "com.x", "key": "seen"], devices: simulators
        ) == .ok(#"{"key":"seen","present":true,"type":"bool","value":false}"#))
        #expect(await Server.readDefaults(
            udid: "U", query: ["bundleId": "com.x", "key": "gone"], devices: simulators
        ) == .ok(#"{"key":"gone","present":false}"#))
    }

    @Test func `should refuse a read without a bundle id`() async {
        let (simulators, _) = host()
        #expect(await Server.readDefaults(udid: "U", query: [:], devices: simulators)
            == .badRequest("\"\" is not a bundle or App Group identifier"))
    }

    @Test func `should report an unknown device when reading defaults on an unknown udid`() async {
        let (simulators, _) = host()
        #expect(await Server.readDefaults(udid: "nope", query: ["bundleId": "com.x"], devices: simulators)
            == .unknownDevice)
    }

    @Test func `should report a missing app or group as not found`() async {
        let (simulators, _) = host(failure: .groupNotFound(group: "group.x", bundleID: "com.x"))
        #expect(await Server.readDefaults(
            udid: "U", query: ["bundleId": "com.x", "suite": "group.x"], devices: simulators
        ) == .notFound(DefaultsError.groupNotFound(group: "group.x", bundleID: "com.x").description))
    }

    @Test func `should report a shut-down simulator as a conflict`() async {
        let (simulators, _) = host(failure: .deviceNotBooted)
        #expect(await Server.readDefaults(udid: "U", query: ["bundleId": "com.x"], devices: simulators)
            == .conflict(DefaultsError.deviceNotBooted.description))
    }

    @Test func `should report any other simctl failure as failed`() async {
        let (simulators, _) = host(failure: .simctlFailed(status: 1))
        #expect(await Server.readDefaults(udid: "U", query: ["bundleId": "com.x"], devices: simulators)
            == .failed("xcrun simctl exited 1"))
    }

    // MARK: - write

    @Test func `should write a typed value from a JSON body`() async {
        let (simulators, journal) = host()
        let outcome = await Server.writeDefaults(
            udid: "U",
            body: #"{"bundleId":"com.x","suite":"group.x","key":"n","type":"int","value":3}"#,
            devices: simulators
        )
        #expect(outcome == .ok(#"{"ok":true,"relaunched":false}"#))
        #expect(journal.steps == ["write group.x n=<integer>3</integer>"])
    }

    @Test func `should take a JSON boolean as the value of a bool`() async {
        let (simulators, journal) = host()
        _ = await Server.writeDefaults(
            udid: "U", body: #"{"bundleId":"com.x","key":"seen","type":"bool","value":false}"#,
            devices: simulators
        )
        #expect(journal.steps == ["write com.x seen=<false/>"])
    }

    @Test func `should relaunch the app around a write when the body asks to`() async {
        let (simulators, journal) = host()
        _ = await Server.writeDefaults(
            udid: "U",
            body: #"{"bundleId":"com.x","key":"s","type":"string","value":"hi","relaunch":true}"#,
            devices: simulators
        )
        #expect(journal.steps == ["terminate com.x", "write com.x s=<string>hi</string>", "launch com.x"])
    }

    @Test func `should change a setting the running app watches without relaunching it when the body asks to relaunch only as needed`() async {
        let (simulators, journal) = host(lookups: PreferenceLookups(pid: 9, all: [
            PreferenceLookup(key: "theme", type: .string, live: true),
        ]))
        let outcome = await Server.writeDefaults(
            udid: "U",
            body: #"{"bundleId":"com.x","key":"theme","type":"string","value":"Light","relaunch":"whenNeeded"}"#,
            devices: simulators
        )
        #expect(outcome == .ok(#"{"ok":true,"relaunched":false}"#))
        #expect(journal.steps == ["write com.x theme=<string>Light</string>"])
    }

    @Test func `should relaunch around a setting the running app read only once when the body asks to relaunch only as needed`() async {
        let (simulators, journal) = host(lookups: PreferenceLookups(pid: 9, all: [
            PreferenceLookup(key: "desk", type: .string),
        ]))
        let outcome = await Server.writeDefaults(
            udid: "U",
            body: #"{"bundleId":"com.x","key":"desk","type":"string","value":"board","relaunch":"whenNeeded"}"#,
            devices: simulators
        )
        #expect(outcome == .ok(#"{"ok":true,"relaunched":true}"#))
        #expect(journal.steps == ["terminate com.x", "write com.x desk=<string>board</string>", "launch com.x"])
    }

    @Test func `should refuse a relaunch that is not always, never or as needed`() async {
        let (simulators, journal) = host()
        #expect(await Server.writeDefaults(
            udid: "U", body: #"{"bundleId":"com.x","key":"k","type":"bool","value":true,"relaunch":"sometimes"}"#,
            devices: simulators
        ) == .badRequest(#"relaunch must be true, false or "whenNeeded""#))
        #expect(journal.steps.isEmpty)
    }

    @Test func `should refuse a write body that is not a typed preference`() async {
        let (simulators, journal) = host()
        for body in [
            "not json",
            #"{"bundleId":"com.x","type":"bool","value":true}"#,
            #"{"bundleId":"com.x","key":"k","type":"double","value":1}"#,
            #"{"bundleId":"com.x","key":"k","type":"bool"}"#,
        ] {
            let outcome = await Server.writeDefaults(udid: "U", body: body, devices: simulators)
            guard case .badRequest = outcome else {
                Issue.record("expected badRequest for \(body), got \(outcome)")
                continue
            }
        }
        #expect(await Server.writeDefaults(
            udid: "U", body: #"{"bundleId":"com.x","key":"k","type":"int","value":"x"}"#,
            devices: simulators
        ) == .badRequest(#""x" is not a valid int"#))
        #expect(journal.steps.isEmpty)
    }

    // MARK: - delete

    @Test func `should delete a key and say whether it was stored`() async {
        let (simulators, journal) = host()
        #expect(await Server.deleteDefaults(
            udid: "U", query: ["bundleId": "com.x", "key": "seen"], devices: simulators
        ) == .ok(#"{"ok":true,"relaunched":false,"removed":true}"#))
        #expect(await Server.deleteDefaults(
            udid: "U", query: ["bundleId": "com.x", "key": "gone", "relaunch": "1"], devices: simulators
        ) == .ok(#"{"ok":true,"relaunched":true,"removed":false}"#))
        #expect(journal.steps == ["delete seen", "terminate com.x", "launch com.x"])
    }

    @Test func `should refuse a delete without a key`() async {
        let (simulators, _) = host()
        #expect(await Server.deleteDefaults(udid: "U", query: ["bundleId": "com.x"], devices: simulators)
            == .badRequest("key is required"))
    }

    @Test func `should report a relaunch that failed`() async {
        let apps = MockApps()
        let simulators = routeDevices {
            $0.register(.defaults) { MockDefaults() }
            $0.register(.apps) { apps }
        }
        given(apps).terminate(bundleID: .any).willThrow(AppsError.terminateFailed(status: 9))
        #expect(await Server.deleteDefaults(
            udid: "U", query: ["bundleId": "com.x", "key": "k", "relaunch": "true"], devices: simulators
        ) == .failed("xcrun simctl terminate exited 9"))
    }

    // MARK: - import

    @Test func `should import a saved set of values from a JSON body, relaunching once`() async {
        let (simulators, journal) = host()
        let outcome = await Server.writeDefaults(
            udid: "U",
            body: #"{"bundleId":"com.x","relaunch":true,"values":{"b":{"type":"int","value":2},"a":{"type":"bool","value":true}}}"#,
            devices: simulators
        )
        #expect(outcome == .ok(#"{"ok":true,"relaunched":true,"written":2}"#))
        #expect(journal.steps == [
            "terminate com.x", "write com.x a=<true/>", "write com.x b=<integer>2</integer>", "launch com.x",
        ])
    }

    @Test func `should refuse an import with an untyped value, naming its key`() async {
        let (simulators, journal) = host()
        #expect(await Server.writeDefaults(
            udid: "U", body: #"{"bundleId":"com.x","values":{"seen":false}}"#, devices: simulators
        ) == .badRequest(PreferencesImportError.untyped(key: "seen").description))
        #expect(journal.steps.isEmpty)
    }

    // MARK: - what the editor card needs

    @Test func `should list installed apps by name, marking Apple's own`() async {
        let (simulators, _) = host()
        let expected: String = #"{"apps":[{"bundleId":"com.x.app","name":"Alpha","system":false},"#
            + #"{"bundleId":"com.x.bench","name":"bench","system":false},"#
            + #"{"bundleId":"com.apple.mobilesafari","name":"Safari","system":true}]}"#
        #expect(await Server.installedApps(udid: "U", devices: simulators) == .ok(expected))
    }

    @Test func `should list an app's App Groups for the suite picker`() async {
        let (simulators, _) = host()
        #expect(await Server.defaultsGroups(udid: "U", query: ["bundleId": "com.x"], devices: simulators)
            == .ok(#"{"bundleId":"com.x","groups":["group.x","group.y"]}"#))
    }

    @Test func `should refuse to list groups without a bundle id`() async {
        let (simulators, _) = host()
        guard case .badRequest = await Server.defaultsGroups(udid: "U", query: [:], devices: simulators) else {
            Issue.record("expected badRequest"); return
        }
    }

    @Test func `should carry plist text for collections when the editor asks`() async {
        let (simulators, _) = host(stored: ["tags": .array([.bool(true)])])
        #expect(await Server.readDefaults(
            udid: "U", query: ["bundleId": "com.x", "plist": "1"], devices: simulators
        ) == .ok(#"{"bundleId":"com.x","lookups":{"answered":false},"values":{"tags":{"plist":"<array><true/></array>","type":"array","value":[{"type":"bool","value":true}]}}}"#))
    }

    @Test func `should relaunch an app on its own`() async {
        let (simulators, journal) = host()
        #expect(await Server.relaunchApp(udid: "U", query: ["bundleId": "com.x"], devices: simulators)
            == .ok(#"{"ok":true}"#))
        #expect(journal.steps == ["terminate com.x", "launch com.x"])
    }

    @Test func `should report an unknown device when relaunching on an unknown udid`() async {
        let (simulators, _) = host()
        #expect(await Server.relaunchApp(udid: "nope", query: ["bundleId": "com.x"], devices: simulators)
            == .unknownDevice)
    }

    @Test func `should refuse to read the defaults of a device that has none, naming it`() async {
        let phone = routeDevices(name: "han's iPhone")

        #expect(await Server.readDefaults(udid: "U", query: ["bundleId": "com.x"], devices: phone)
            == .refused(.unable(ability: "defaults", device: "han's iPhone")))
    }

    @Test func `should answer the defaults routes under the devices tree and a simulator's old one`() {
        for leaf in ["defaults.json", "defaults", "apps.json", "defaults-groups.json", "relaunch"] {
            #expect(Server.deviceRoutes(leaf) == ["/devices/:udid/\(leaf)", "/simulators/:udid/\(leaf)"])
        }
    }

    @Test func `should find the device in every defaults route's path`() {
        for path in [
            "/simulators/UDID-1/defaults.json", "/simulators/UDID-1/defaults",
            "/simulators/UDID-1/apps.json", "/simulators/UDID-1/defaults-groups.json",
            "/simulators/UDID-1/relaunch",
        ] {
            #expect(Server.udid(inPath: path) == "UDID-1", "\(path)")
            #expect(Server.defaultsRoutePaths.contains(String(path.dropFirst("/simulators/UDID-1".count))), "\(path)")
        }
    }
}
