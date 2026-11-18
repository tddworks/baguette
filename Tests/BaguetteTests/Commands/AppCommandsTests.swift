import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// `baguette install`, `add-media`, `openurl` and `schemes` against the
/// devices a test hands them.
@Suite("App commands")
struct AppCommandsTests {

    private struct Refused: Error, CustomStringConvertible {
        var description: String { "refused" }
    }

    private func apps(failing: Bool = false, installed: [InstalledApp] = []) -> MockApps {
        let apps = MockApps()
        if failing {
            given(apps).install(.any as Parameter<AppBundle>).willThrow(Refused())
            given(apps).open(.any).willThrow(Refused())
            given(apps).installed().willThrow(Refused())
        } else {
            given(apps).install(.any as Parameter<AppBundle>).willReturn()
            given(apps).open(.any).willReturn()
            given(apps).installed().willReturn(installed)
        }
        return apps
    }

    private func devices(_ apps: MockApps) -> any Devices {
        routeDevices { $0.register(.apps) { apps } }
    }

    // MARK: - install

    @Test func `should install the app at the path given and say so`() async throws {
        let ran = try await run(try InstallCommand.parse(["--udid", "U", "/tmp/Demo.app"]), on: devices(apps()))

        #expect(ran.exit == 0)
        #expect(ran.told == ["Installed Demo.app on iPhone 17"])
    }

    @Test func `should exit 1 when the path is not an app`() async throws {
        let ran = try await run(try InstallCommand.parse(["--udid", "U", "/tmp/notes.txt"]), on: devices(apps()))

        #expect(ran.exit == 1)
        #expect(ran.told == ["Not an installable app (expected .ipa or .app): /tmp/notes.txt"])
    }

    @Test func `should exit 1 when the install fails`() async throws {
        let ran = try await run(try InstallCommand.parse(["--udid", "U", "/tmp/Demo.ipa"]),
                                on: devices(apps(failing: true)))

        #expect(ran.exit == 1)
        #expect(ran.told == ["install failed: refused"])
    }

    @Test func `should exit 1 installing onto a device that has no apps`() async throws {
        let ran = try await run(try InstallCommand.parse(["--udid", "U", "/tmp/Demo.app"]), on: routeDevices())

        #expect(ran.exit == 1)
        #expect(ran.told == ["iPhone 17 can't do apps"])
    }

    // MARK: - add-media

    private func photos(failing: Bool = false) -> any Devices {
        let photos = MockPhotoLibrary()
        if failing { given(photos).add(.any).willThrow(Refused()) } else { given(photos).add(.any).willReturn() }
        return routeDevices { $0.register(.photos) { photos } }
    }

    @Test func `should add the photo at the path given to the device's Photos`() async throws {
        let ran = try await run(try AddMediaCommand.parse(["--udid", "U", "/tmp/cat.jpg"]), on: photos())

        #expect(ran.exit == 0)
        #expect(ran.told == ["Added cat.jpg to iPhone 17 Photos"])
    }

    @Test func `should exit 1 when the path is not a photo or video`() async throws {
        let ran = try await run(try AddMediaCommand.parse(["--udid", "U", "/tmp/cat.txt"]), on: photos())

        #expect(ran.exit == 1)
        #expect(ran.told == ["Not a supported image or video: /tmp/cat.txt"])
    }

    @Test func `should exit 1 when adding the media fails`() async throws {
        let ran = try await run(try AddMediaCommand.parse(["--udid", "U", "/tmp/cat.png"]), on: photos(failing: true))

        #expect(ran.exit == 1)
        #expect(ran.told == ["add-media failed: refused"])
    }

    @Test func `should exit 1 adding media to a device with no Photos`() async throws {
        let ran = try await run(try AddMediaCommand.parse(["--udid", "U", "/tmp/cat.png"]), on: routeDevices())

        #expect(ran.exit == 1)
        #expect(ran.told == ["iPhone 17 can't do photos"])
    }

    // MARK: - openurl

    @Test func `should open a custom-scheme link on the device and say so`() async throws {
        let ran = try await run(try OpenURLCommand.parse(["--udid", "U", "myapp://profile/42"]), on: devices(apps()))

        #expect(ran.exit == 0)
        #expect(ran.told == ["Opened myapp://profile/42 on iPhone 17"])
    }

    @Test func `should warn that a web link lands in Safari before opening it`() async throws {
        let ran = try await run(try OpenURLCommand.parse(["--udid", "U", "https://example.com/a"]), on: devices(apps()))

        #expect(ran.told.count == 2)
        #expect(ran.told.first?.hasPrefix("Warning: https:// lands in Safari") == true)
        #expect(ran.told.last == "Opened https://example.com/a on iPhone 17")
    }

    @Test func `should exit 1 when the link is not a URL`() async throws {
        let ran = try await run(try OpenURLCommand.parse(["--udid", "U", "profile"]), on: devices(apps()))

        #expect(ran.exit == 1)
        #expect(ran.told == ["Not a URL (expected a scheme, e.g. myapp://path): profile"])
    }

    @Test func `should exit 1 when opening the link fails`() async throws {
        let ran = try await run(try OpenURLCommand.parse(["--udid", "U", "myapp://x"]), on: devices(apps(failing: true)))

        #expect(ran.exit == 1)
        #expect(ran.told == ["openurl failed: refused"])
    }

    // MARK: - schemes

    private let notes = InstalledApp(bundleIdentifier: "com.example.notes", name: "Notes", schemes: ["notes"])

    @Test func `should list each scheme with the app that answers it`() async throws {
        let ran = try await run(try SchemesCommand.parse(["--udid", "U"]), on: devices(apps(installed: [notes])))

        #expect(ran.said == ["notes://  Notes"])
    }

    @Test func `should list the schemes as JSON when asked`() async throws {
        let ran = try await run(try SchemesCommand.parse(["--udid", "U", "--json"]),
                                on: devices(apps(installed: [notes])))

        let rows = try #require(
            JSONSerialization.jsonObject(with: Data(ran.said.joined().utf8)) as? [[String: String]])
        #expect(rows == [["scheme": "notes", "url": "notes://", "app": "Notes", "bundleId": "com.example.notes"]])
    }

    @Test func `should say so when no app registers a scheme`() async throws {
        let ran = try await run(try SchemesCommand.parse(["--udid", "U"]), on: devices(apps()))

        #expect(ran.exit == 0)
        #expect(ran.told == ["No app on iPhone 17 registers a URL scheme"])
    }

    @Test func `should exit 1 when the device can't list its apps`() async throws {
        let ran = try await run(try SchemesCommand.parse(["--udid", "U"]), on: devices(apps(failing: true)))

        #expect(ran.exit == 1)
        #expect(ran.told == ["listing apps failed: refused"])
    }
}
