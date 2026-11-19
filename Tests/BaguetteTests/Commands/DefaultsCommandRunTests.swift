import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// `baguette defaults` run against the devices a test hands it.
@Suite("Defaults command run")
struct DefaultsCommandRunTests {

    private struct Refused: Error, CustomStringConvertible {
        var description: String { "refused" }
    }

    private let app = ["--udid", "U", "--bundle-id", "com.x"]

    private func storing(_ values: [String: PreferenceValue] = ["seen": .bool(true)], failing: Bool = false)
        -> any Devices
    {
        let defaults = MockDefaults()
        if failing {
            given(defaults).read(.any).willThrow(Refused())
            given(defaults).write(.any, forKey: .any, in: .any).willThrow(Refused())
        } else {
            given(defaults).read(.any).willReturn(Preferences(values: values))
            given(defaults).write(.any, forKey: .any, in: .any).willReturn()
        }
        given(defaults).delete(key: .any, in: .any).willReturn()
        given(defaults).lookups(of: .any).willReturn(nil)
        let apps = MockApps()
        return routeDevices {
            $0.register(.defaults) { defaults }
            $0.register(.apps) { apps }
        }
    }

    // MARK: - read

    @Test func `should answer one key's stored value and type`() async throws {
        let ran = try await run(try DefaultsCommand.Read.parse(app + ["--key", "seen"]), on: storing())

        #expect(ran.said == ["seen = true (bool)"])
    }

    @Test func `should answer every stored value as typed JSON`() async throws {
        let ran = try await run(try DefaultsCommand.Read.parse(app + ["--json"]), on: storing())

        let answer = try #require(
            JSONSerialization.jsonObject(with: Data(ran.said.joined().utf8)) as? [String: Any])
        #expect(answer["bundleId"] as? String == "com.x")
        let values = try #require(answer["values"] as? [String: [String: Any]])
        #expect(values["seen"]?["value"] as? Bool == true)
    }

    @Test func `should exit 1 when the defaults can't be read`() async throws {
        let ran = try await run(try DefaultsCommand.Read.parse(app), on: storing(failing: true))

        #expect(ran.exit == 1)
        #expect(ran.told == ["defaults read failed: refused"])
    }

    @Test func `should exit 1 reading the defaults of a device without them`() async throws {
        let ran = try await run(try DefaultsCommand.Read.parse(app), on: routeDevices())

        #expect(ran.exit == 1)
        #expect(ran.told == ["iPhone 17 can't do defaults"])
    }

    // MARK: - write, delete

    @Test func `should store the typed value and say so`() async throws {
        let ran = try await run(
            try DefaultsCommand.Write.parse(app + ["--key", "seen", "--type", "bool", "--value", "false"]),
            on: storing())

        #expect(ran.exit == 0)
        #expect(ran.told == ["Wrote seen for com.x"])
    }

    @Test func `should exit 1 when the value can't be stored`() async throws {
        let ran = try await run(
            try DefaultsCommand.Write.parse(app + ["--key", "seen", "--type", "bool", "--value", "false"]),
            on: storing(failing: true))

        #expect(ran.exit == 1)
        #expect(ran.told == ["defaults write failed: refused"])
    }

    @Test func `should remove a stored key and say so`() async throws {
        let ran = try await run(try DefaultsCommand.Delete.parse(app + ["--key", "seen"]), on: storing())

        #expect(ran.told == ["Removed seen"])
    }

    @Test func `should say nothing was removed when the key was not stored`() async throws {
        let ran = try await run(try DefaultsCommand.Delete.parse(app + ["--key", "gone"]), on: storing())

        #expect(ran.told == ["gone was not set; nothing removed"])
    }

    @Test func `should exit 1 when the key can't be removed`() async throws {
        let ran = try await run(try DefaultsCommand.Delete.parse(app + ["--key", "seen"]), on: storing(failing: true))

        #expect(ran.exit == 1)
        #expect(ran.told == ["defaults delete failed: refused"])
    }

    // MARK: - export, import

    @Test func `should export the stored values as JSON import reads back`() async throws {
        let ran = try await run(try DefaultsCommand.Export.parse(app), on: storing())

        let exported = Data(ran.said.joined(separator: "\n").utf8)
        #expect(try Preferences(importing: exported) == Preferences(values: ["seen": .bool(true)]))
    }

    @Test func `should exit 1 when there is nothing to export`() async throws {
        let ran = try await run(try DefaultsCommand.Export.parse(app), on: storing(failing: true))

        #expect(ran.exit == 1)
        #expect(ran.told == ["defaults export failed: refused"])
    }

    private var exported: String {
        let suite = try! PreferenceSuite(bundleID: "com.x")
        let object = Preferences(values: ["seen": .bool(true), "n": .integer(3)]).json(in: suite)
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    @Test func `should import every value in the file piped in and say how many`() async throws {
        let ran = try await run(try DefaultsCommand.Import.parse(app + ["--file", "-"]), on: storing(),
                                terminal: Terminal(lines: [exported]))

        #expect(ran.exit == 0)
        #expect(ran.told == ["Imported 2 values into com.x"])
    }

    @Test func `should import every value in the file given`() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("prefs-\(UUID()).json")
        try Data(exported.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let ran = try await run(try DefaultsCommand.Import.parse(app + ["--file", file.path]), on: storing())

        #expect(ran.told == ["Imported 2 values into com.x"])
    }

    @Test func `should exit 1 when the import file can't be read`() async throws {
        let ran = try await run(try DefaultsCommand.Import.parse(app + ["--file", "/nonexistent/p.json"]),
                                on: storing())

        #expect(ran.exit == 1)
        #expect(ran.told.first?.hasPrefix("defaults import failed:") == true)
    }
}
