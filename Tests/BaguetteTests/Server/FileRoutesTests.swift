import Testing
import Foundation
import Mockable
@testable import Baguette

/// Handler-level coverage for the file-upload route. We test the pure
/// dispatch helper (`Server.addFile`) rather than the Hummingbird
/// `Response` wrapper — every branch driven with one device's
/// `MockApps` / `MockPhotoLibrary`.
///
/// `addFile` is the thin "which collection?" router: an app file goes
/// to `apps().install`, media to `photos().add`, and anything with no
/// home on a simulator is refused out loud (never silently dropped).
/// Classification is by extension, so the tests pass plain paths — no
/// bytes need exist on disk.
@Suite("Server file routes")
struct FileRoutesTests {

    @Test func `should install a dropped .ipa on the simulator`() async {
        let apps = MockApps()
        let host = routeDevices { $0.register(.apps) { apps } }
        given(apps).install(.any).willReturn(())

        let outcome = await Server.addFile(
            udid: "U", path: URL(fileURLWithPath: "/tmp/up/MyApp.ipa"), devices: host
        )
        #expect(outcome == .installed)
        verify(apps).install(.value(AppBundle(path: URL(fileURLWithPath: "/tmp/up/MyApp.ipa")))).called(1)
    }

    @Test func `should add a dropped photo to the simulator's photo library`() async {
        let photos = MockPhotoLibrary()
        let host = routeDevices { $0.register(.photos) { photos } }
        given(photos).add(.any).willReturn(())

        let outcome = await Server.addFile(
            udid: "U", path: URL(fileURLWithPath: "/tmp/up/shot.png"), devices: host
        )
        #expect(outcome == .added)
        verify(photos).add(.value(MediaItem(path: URL(fileURLWithPath: "/tmp/up/shot.png")))).called(1)
    }

    // MARK: - what a given route will accept

    @Test func `should refuse an app on the media route`() async {
        // `/media` carries the `media` capability. Installing software
        // through it would let a plugin trusted only to add photos put
        // an executable on the device.
        let apps = MockApps()
        let host = routeDevices { $0.register(.apps) { apps } }

        let outcome = await Server.addFile(
            udid: "U", path: URL(fileURLWithPath: "/tmp/up/MyApp.ipa"),
            devices: host, allowing: .media
        )
        #expect(outcome == .wrongKind(ext: "ipa"))
        verify(apps).install(.any).called(0)
    }

    @Test func `should refuse a photo on the apps route`() async {
        let photos = MockPhotoLibrary()
        let host = routeDevices { $0.register(.photos) { photos } }

        let outcome = await Server.addFile(
            udid: "U", path: URL(fileURLWithPath: "/tmp/up/shot.png"),
            devices: host, allowing: .apps
        )
        #expect(outcome == .wrongKind(ext: "png"))
        verify(photos).add(.any).called(0)
    }

    @Test func `should take both apps and photos on the browser's drag-and-drop route`() async {
        // `/files` is the one entry point that classifies for you, which
        // is why it is closed to plugins entirely.
        let apps = MockApps()
        let photos = MockPhotoLibrary()
        let host = routeDevices {
            $0.register(.apps) { apps }
            $0.register(.photos) { photos }
        }
        given(apps).install(.any).willReturn(())
        given(photos).add(.any).willReturn(())

        #expect(await Server.addFile(
            udid: "U", path: URL(fileURLWithPath: "/tmp/up/MyApp.ipa"),
            devices: host, allowing: .all
        ) == .installed)
        #expect(await Server.addFile(
            udid: "U", path: URL(fileURLWithPath: "/tmp/up/shot.png"),
            devices: host, allowing: .all
        ) == .added)
    }

    @Test func `should refuse a file that has no home on a simulator`() async {
        let host = routeDevices()

        let outcome = await Server.addFile(
            udid: "U", path: URL(fileURLWithPath: "/tmp/up/notes.pdf"), devices: host
        )
        #expect(outcome == .unsupported(ext: "pdf"))
    }

    @Test func `should refuse an app for a device that can't install one, naming it`() async {
        let host = routeDevices(name: "han's iPhone") { $0.register(.photos) { MockPhotoLibrary() } }

        #expect(await Server.addFile(
            udid: "U", path: URL(fileURLWithPath: "/tmp/up/MyApp.ipa"), devices: host
        ) == .refused(.unable(ability: "apps", device: "han's iPhone")))
    }

    @Test func `should answer uploads under the devices tree and a simulator's old one`() {
        for leaf in ["files", "apps", "media", "camera-source"] {
            #expect(Server.deviceRoutes(leaf) == ["/devices/:udid/\(leaf)", "/simulators/:udid/\(leaf)"])
        }
    }

    @Test func `should report an unknown device when a file is added for an unknown udid`() async {
        let host = routeDevices()
        let outcome = await Server.addFile(
            udid: "ghost", path: URL(fileURLWithPath: "/tmp/up/MyApp.ipa"), devices: host
        )
        #expect(outcome == .unknownDevice)
    }

    @Test func `should install a zipped .app as an archive`() async {
        let apps = MockApps()
        let host = routeDevices { $0.register(.apps) { apps } }
        given(apps).install(archive: .any).willReturn(())

        let outcome = await Server.addFile(
            udid: "U", path: URL(fileURLWithPath: "/tmp/up/MyApp.app.zip"), devices: host
        )
        #expect(outcome == .installed)
        verify(apps).install(archive: .value(AppArchive(path: URL(fileURLWithPath: "/tmp/up/MyApp.app.zip")))).called(1)
    }

    @Test func `should refuse a zip with no app inside and say why`() async {
        let apps = MockApps()
        let host = routeDevices { $0.register(.apps) { apps } }
        given(apps).install(archive: .any).willThrow(AppsError.noAppInArchive)

        let outcome = await Server.addFile(
            udid: "U", path: URL(fileURLWithPath: "/tmp/up/docs.zip"), devices: host
        )
        #expect(outcome == .badArchive(reason: "no single .app bundle at the top level of the zip"))
    }

    @Test func `should refuse a corrupt zip with the extract failure`() async {
        let apps = MockApps()
        let host = routeDevices { $0.register(.apps) { apps } }
        given(apps).install(archive: .any).willThrow(AppsError.extractFailed(status: 2))

        let outcome = await Server.addFile(
            udid: "U", path: URL(fileURLWithPath: "/tmp/up/broken.zip"), devices: host
        )
        #expect(outcome == .badArchive(reason: "ditto -x -k exited 2 (corrupt zip?)"))
    }

    @Test func `should refuse a zip that inflates past the extraction cap and say why`() async {
        let apps = MockApps()
        let host = routeDevices { $0.register(.apps) { apps } }
        given(apps).install(archive: .any)
            .willThrow(AppsError.archiveTooLarge(bytes: 8_589_934_592, limit: 4_294_967_296))

        let outcome = await Server.addFile(
            udid: "U", path: URL(fileURLWithPath: "/tmp/up/bomb.zip"), devices: host
        )
        #expect(outcome == .badArchive(
            reason: "archive inflates to 8589934592 bytes, over the 4294967296-byte cap (zip bomb?)"
        ))
    }

    @Test func `should report a failed dispatch when simctl cannot install a zipped app`() async {
        let apps = MockApps()
        let host = routeDevices { $0.register(.apps) { apps } }
        given(apps).install(archive: .any).willThrow(AppsError.installFailed(status: 1))

        let outcome = await Server.addFile(
            udid: "U", path: URL(fileURLWithPath: "/tmp/up/MyApp.app.zip"), devices: host
        )
        #expect(outcome == .dispatchFailed)
    }

    @Test func `should report a failed dispatch when simctl cannot install an .ipa`() async {
        let apps = MockApps()
        let host = routeDevices { $0.register(.apps) { apps } }
        given(apps).install(.any).willThrow(AppsError.installFailed(status: 1))

        let outcome = await Server.addFile(
            udid: "U", path: URL(fileURLWithPath: "/tmp/up/MyApp.ipa"), devices: host
        )
        #expect(outcome == .dispatchFailed)
    }
}
