import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// What `baguette defaults` prints once the device's defaults answer:
/// read's text or JSON, export's JSON, and the line each edit logs.
@Suite("Defaults command answers")
struct DefaultsAnswerTests {

    private static let stored = Preferences(values: ["seen": .bool(true), "count": .integer(3)])

    private func defaults(lookups: PreferenceLookups? = nil) -> MockDefaults {
        let defaults = MockDefaults()
        given(defaults).read(.any).willReturn(Self.stored)
        given(defaults).lookups(of: .any).willReturn(lookups)
        return defaults
    }

    // MARK: - read

    @Test func `should read every stored preference as text when no key is named`() async throws {
        let cmd = try DefaultsCommand.Read.parse(["--udid", "U", "--bundle-id", "com.x"])

        let answer = try await cmd.answer(from: defaults())

        #expect(answer == DefaultsCommand.Read.text(Self.stored, key: nil))
    }

    @Test func `should read one key as JSON without asking the running app when a key is named`() async throws {
        let cmd = try DefaultsCommand.Read.parse(["--udid", "U", "--bundle-id", "com.x", "--key", "seen", "--json"])
        let defaults = MockDefaults()
        given(defaults).read(.any).willReturn(Self.stored)

        let answer = try await cmd.answer(from: defaults)

        let object = try #require(JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any])
        #expect(object["lookups"] == nil)
        #expect(object["key"] as? String == "seen")
    }

    @Test func `should say in JSON that no running app answered when reading everything`() async throws {
        let cmd = try DefaultsCommand.Read.parse(["--udid", "U", "--bundle-id", "com.x", "--json"])

        let answer = try await cmd.answer(from: defaults())

        let object = try #require(JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any])
        let lookups = try #require(object["lookups"] as? [String: Any])
        #expect(lookups["answered"] as? Bool == false)
    }

    // MARK: - export

    @Test func `should export only the keys named, as pretty JSON`() async throws {
        let cmd = try DefaultsCommand.Export.parse(["--udid", "U", "--bundle-id", "com.x", "--key", "seen"])

        let answer = try await cmd.answer(from: defaults())

        #expect(answer.contains("\n"))
        let object = try #require(JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any])
        let values = try #require(object["values"] as? [String: Any])
        #expect(Set(values.keys) == ["seen"])
    }

    // MARK: - edits

    @Test func `should say which key was written and for which suite`() throws {
        let cmd = try DefaultsCommand.Write.parse([
            "--udid", "U", "--bundle-id", "com.x", "--suite", "group.x",
            "--key", "seen", "--type", "bool", "--value", "true",
        ])

        #expect(cmd.said(PreferenceEdit.Applied(changed: true, relaunched: false)) == "Wrote seen for group.x")
    }

    @Test func `should say the app was relaunched after a write when it was`() throws {
        let cmd = try DefaultsCommand.Write.parse([
            "--udid", "U", "--bundle-id", "com.x", "--key", "seen", "--type", "bool", "--value", "true", "--relaunch",
        ])

        #expect(cmd.said(PreferenceEdit.Applied(changed: true, relaunched: true))
            == "Wrote seen for com.x and relaunched com.x")
    }

    @Test func `should say a key was removed`() throws {
        let cmd = try DefaultsCommand.Delete.parse(["--udid", "U", "--bundle-id", "com.x", "--key", "seen"])

        #expect(cmd.said(PreferenceEdit.Applied(changed: true, relaunched: false)) == "Removed seen")
    }

    @Test func `should say nothing was removed when the key was not set`() throws {
        let cmd = try DefaultsCommand.Delete.parse(["--udid", "U", "--bundle-id", "com.x", "--key", "seen"])

        #expect(cmd.said(PreferenceEdit.Applied(changed: false, relaunched: false))
            == "seen was not set; nothing removed")
    }

    @Test func `should count the values imported, singular for one`() throws {
        let cmd = try DefaultsCommand.Import.parse(["--udid", "U", "--bundle-id", "com.x", "--file", "-"])

        #expect(cmd.said(PreferenceImport.Applied(written: 1, relaunched: false)) == "Imported 1 value into com.x")
        #expect(cmd.said(PreferenceImport.Applied(written: 2, relaunched: false)) == "Imported 2 values into com.x")
    }
}
