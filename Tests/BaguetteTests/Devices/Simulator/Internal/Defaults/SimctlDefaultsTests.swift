import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// Orchestration coverage for `SimctlDefaults`: ask simctl for the
/// container, then run the simulator's own `defaults` tool against the
/// plist inside it. Every child is answered by `MockSubprocess`; the
/// exit codes mirror what Xcode 27's simctl was measured to return.
@Suite("SimctlDefaults")
struct SimctlDefaultsTests {

    final class Calls: @unchecked Sendable {
        var argv: [[String]] = []
    }

    private static let container = "/sim/data/Containers/Data/Application/A1"
    private static let plist = container + "/Library/Preferences/com.example.app.plist"

    /// A device whose `get_app_container` answers `containerExit` and whose
    /// `defaults` answers `defaultsExit` with `defaultsOutput`.
    private func makeDefaults(
        containerExit: Int32 = 0,
        container: String = SimctlDefaultsTests.container + "\n",
        defaultsExit: Int32 = 0,
        defaultsOutput: String = "",
        deviceSetPath: String? = nil
    ) -> (SimctlDefaults, Calls) {
        let sub = MockSubprocess()
        let calls = Calls()
        given(sub).run(
            executable: .any, arguments: .any, onBytes: .any, onExit: .any
        ).willProduce { _, args, onBytes, onExit in
            calls.argv.append(args)
            if args.contains("get_app_container") {
                if containerExit == 0 { onBytes(Data(container.utf8)) }
                onExit(containerExit)
            } else {
                onBytes(Data(defaultsOutput.utf8))
                onExit(defaultsExit)
            }
        }
        return (SimctlDefaults(udid: "U", deviceSetPath: deviceSetPath, subprocess: sub), calls)
    }

    private static let app = try! PreferenceSuite(bundleID: "com.example.app")

    @Test func `should read the app's preferences from the plist in its data container`() async throws {
        let (defaults, calls) = makeDefaults(defaultsOutput: """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>seen</key><false/></dict></plist>
        """)

        let preferences = try await defaults.read(Self.app)

        #expect(preferences.values == ["seen": .bool(false)])
        #expect(calls.argv == [
            ["simctl", "get_app_container", "U", "com.example.app", "data"],
            ["simctl", "spawn", "U", "defaults", "export", Self.plist, "-"],
        ])
    }

    @Test func `should edit the app's preferences inside the device's custom device set when it lives in one`() async throws {
        let (defaults, calls) = makeDefaults(deviceSetPath: "/custom set")

        try await defaults.write(.integer(3), forKey: "launches", in: Self.app)

        #expect(calls.argv == [
            ["simctl", "--set", "/custom set", "get_app_container", "U", "com.example.app", "data"],
            ["simctl", "--set", "/custom set", "spawn", "U", "defaults", "write", Self.plist, "launches", "<integer>3</integer>"],
        ])
    }

    @Test func `should list an app's App Groups inside the device's custom device set when it lives in one`() async throws {
        let (defaults, calls) = makeDefaults(container: "group.a\t/sim/G1\n", deviceSetPath: "/custom set")
        #expect(try await defaults.groups(of: "com.example.app") == ["group.a"])
        #expect(calls.argv == [["simctl", "--set", "/custom set", "get_app_container", "U", "com.example.app", "groups"]])
    }

    @Test func `should store a value as a typed plist fragment`() async throws {
        let (defaults, calls) = makeDefaults()

        try await defaults.write(.integer(3), forKey: "launches", in: Self.app)

        #expect(calls.argv.last
            == ["simctl", "spawn", "U", "defaults", "write", Self.plist, "launches", "<integer>3</integer>"])
    }

    @Test func `should remove a key from the app's plist`() async throws {
        let (defaults, calls) = makeDefaults()

        try await defaults.delete(key: "seen", in: Self.app)

        #expect(calls.argv.last == ["simctl", "spawn", "U", "defaults", "delete", Self.plist, "seen"])
    }

    @Test func `should read a suite from the plist in its App Group container`() async throws {
        let (defaults, calls) = makeDefaults(
            container: "group.other\t/sim/G0\ngroup.example\t/sim/data/Containers/Shared/AppGroup/G1\n",
            defaultsOutput: #"<plist version="1.0"><dict/></plist>"#
        )
        let suite = try PreferenceSuite(bundleID: "com.example.app", name: "group.example")

        #expect(try await defaults.read(suite).values == [:])
        #expect(calls.argv == [
            ["simctl", "get_app_container", "U", "com.example.app", "groups"],
            ["simctl", "spawn", "U", "defaults", "export",
             "/sim/data/Containers/Shared/AppGroup/G1/Library/Preferences/group.example.plist", "-"],
        ])
    }

    @Test func `should report an app that isn't installed`() async {
        let (defaults, calls) = makeDefaults(containerExit: 2)
        await #expect(throws: DefaultsError.appNotInstalled(bundleID: "com.example.app")) {
            try await defaults.read(Self.app)
        }
        #expect(calls.argv.count == 1)
    }

    @Test func `should report an App Group the app doesn't belong to rather than use standard defaults`() async {
        let (defaults, calls) = makeDefaults(container: "group.other\t/sim/G0\n")
        let suite = try! PreferenceSuite(bundleID: "com.example.app", name: "group.nope")
        await #expect(throws: DefaultsError.groupNotFound(group: "group.nope", bundleID: "com.example.app")) {
            try await defaults.write(.bool(true), forKey: "k", in: suite)
        }
        #expect(calls.argv.count == 1)
    }

    @Test func `should report a container it was never told for a suite that is not an App Group`() async {
        let (defaults, _) = makeDefaults(container: "")
        let suite = try! PreferenceSuite(bundleID: "com.example.app", name: "com.example.debug")
        await #expect(throws: DefaultsError.simctlFailed(status: 0)) {
            try await defaults.read(suite)
        }
    }

    @Test func `should list the App Groups an app has from simctl's groups listing`() async throws {
        let (defaults, calls) = makeDefaults(container: "group.b\t/sim/G2\ngroup.a\t/sim/G1\n")
        #expect(try await defaults.groups(of: "com.example.app") == ["group.a", "group.b"])
        #expect(calls.argv == [["simctl", "get_app_container", "U", "com.example.app", "groups"]])
    }

    @Test func `should report an app that isn't installed when listing its groups`() async {
        let (defaults, _) = makeDefaults(containerExit: 2)
        await #expect(throws: DefaultsError.appNotInstalled(bundleID: "com.example.app")) {
            try await defaults.groups(of: "com.example.app")
        }
    }

    @Test func `should report a simulator that isn't booted`() async {
        let (defaults, _) = makeDefaults(containerExit: 149)
        await #expect(throws: DefaultsError.deviceNotBooted) {
            try await defaults.read(Self.app)
        }
    }

    @Test func `should report a defaults run that failed`() async {
        let (defaults, _) = makeDefaults(defaultsExit: 1)
        await #expect(throws: DefaultsError.simctlFailed(status: 1)) {
            try await defaults.delete(key: "seen", in: Self.app)
        }
    }

    @Test func `should report an export it can't read as a suite`() async {
        let (defaults, _) = makeDefaults(defaultsOutput: "Invalid device")
        await #expect(throws: DefaultsError.unreadableDomain) {
            try await defaults.read(Self.app)
        }
    }

    @Test func `should report a container it was never told`() async {
        let (defaults, calls) = makeDefaults(container: "\n")
        await #expect(throws: DefaultsError.simctlFailed(status: 0)) {
            try await defaults.read(Self.app)
        }
        #expect(calls.argv.count == 1)
    }

    @Test func `should surface a spawn that could not start`() async {
        let sub = MockSubprocess()
        given(sub).run(executable: .any, arguments: .any, onBytes: .any, onExit: .any)
            .willThrow(SubprocessError.notInteractive)
        let defaults = SimctlDefaults(udid: "U", subprocess: sub)
        await #expect(throws: SubprocessError.notInteractive) {
            try await defaults.read(Self.app)
        }
    }

    // MARK: - asking the running app what it looked up

    /// A directory holding one app's answer, written by `pid`.
    private func answering(_ plist: [String: Any]?, running: Set<Int32>) throws -> SimctlDefaults {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lookups-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let plist {
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: directory.appendingPathComponent(
                    SimctlDefaults.answerFileName(udid: "U", bundleID: "com.example.app")))
        }
        return SimctlDefaults(
            udid: "U", subprocess: MockSubprocess(),
            answers: directory, isRunning: { running.contains($0) }
        )
    }

    @Test func `should hear which preferences the running app looked up`() async throws {
        let defaults = try answering(
            ["pid": 7, "lookups": [["key": "desk", "getter": "string"]]], running: [7])
        let lookups = try await defaults.lookups(of: "com.example.app")
        #expect(lookups?.all == [PreferenceLookup(key: "desk", type: .string)])
    }

    @Test func `should hear nothing when the app that answered has quit`() async throws {
        let defaults = try answering(
            ["pid": 7, "lookups": [["key": "desk", "getter": "string"]]], running: [])
        #expect(try await defaults.lookups(of: "com.example.app") == nil)
    }

    @Test func `should hear nothing when the app was not launched able to answer`() async throws {
        let defaults = try answering(nil, running: [7])
        #expect(try await defaults.lookups(of: "com.example.app") == nil)
    }

    @Test func `should keep each simulator's and each app's answer apart`() {
        #expect(SimctlDefaults.answerFileName(udid: "U", bundleID: "com.example.app")
            == "BaguetteLookups-U-com.example.app.plist")
    }
}
