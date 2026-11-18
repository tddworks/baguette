import Foundation
import HTTPTypes
import HummingbirdTesting
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// Files dropped on a device — apps, zipped apps, media — and a camera
/// source, as the router answers them.
@Suite("Serve router: files")
struct FileRouterTests {

    private static func host(installFails: AppsError? = nil, addFails: Bool = false) -> any Devices {
        let apps = MockApps()
        let photos = MockPhotoLibrary()
        if let installFails {
            given(apps).install(.any).willThrow(installFails)
            given(apps).install(archive: .any).willThrow(installFails)
        } else {
            given(apps).install(.any).willReturn()
            given(apps).install(archive: .any).willReturn()
        }
        if addFails {
            given(photos).add(.any).willThrow(RoleFailed())
        } else {
            given(photos).add(.any).willReturn()
        }
        return routeDevices {
            $0.register(.apps) { apps }
            $0.register(.photos) { photos }
        }
    }

    @Test func `should add a dropped photo to the library under both trees`() async throws {
        try await InProcessServer(devices: Self.host()).test { client in
            for path in bothTrees("files?name=photo.png") {
                let response = try await client.send(.post, path, body: "png")

                #expect(response.status == .ok, "\(path)")
                #expect(response.json["kind"] as? String == "media", "\(path)")
            }
        }
    }

    @Test func `should install a dropped app and a zipped one`() async throws {
        try await InProcessServer(devices: Self.host()).test { client in
            let app = try await client.send(.post, "/devices/U/apps?name=Demo.app", body: "app")
            let zip = try await client.send(.post, "/devices/U/files?name=Demo.zip", body: "zip")

            #expect(app.json["kind"] as? String == "app")
            #expect(zip.json["kind"] as? String == "app")
        }
    }

    @Test func `should refuse a file with no home on a device`() async throws {
        try await InProcessServer(devices: Self.host()).test { client in
            #expect(await client.status(.post, "/devices/U/files?name=notes.txt", body: "x") == .unsupportedMediaType)
        }
    }

    @Test func `should refuse media on the apps route and an app on the media route`() async throws {
        try await InProcessServer(devices: Self.host()).test { client in
            let media = try await client.send(.post, "/devices/U/apps?name=photo.png", body: "x")
            let app = try await client.send(.post, "/devices/U/media?name=Demo.app", body: "x")

            #expect(media.status == .unsupportedMediaType)
            #expect(media.json["error"] as? String == ".png is media, not an app — POST it to /media")
            #expect(app.status == .unsupportedMediaType)
        }
    }

    @Test func `should refuse a zip that holds no app`() async throws {
        try await InProcessServer(devices: Self.host(installFails: .noAppInArchive)).test { client in
            #expect(await client.status(.post, "/devices/U/files?name=Demo.zip", body: "x") == .unsupportedMediaType)
        }
    }

    @Test func `should answer a server error when the device won't take the file`() async throws {
        try await InProcessServer(devices: Self.host(installFails: .installFailed(status: 1), addFails: true))
            .test { client in
                #expect(await client.status(.post, "/devices/U/files?name=Demo.app", body: "x")
                    == .internalServerError)
                #expect(await client.status(.post, "/devices/U/media?name=photo.png", body: "x")
                    == .internalServerError)
            }
    }

    @Test func `should refuse a file to a device that can't take it or doesn't exist`() async throws {
        try await InProcessServer().test { client in
            #expect(await client.status(.post, "/devices/U/files?name=Demo.app", body: "x") == .unprocessableContent)
            #expect(await client.status(.post, "/devices/U/files?name=photo.png", body: "x")
                == .unprocessableContent)
            #expect(await client.status(.post, "/devices/U/files?name=Demo.zip", body: "x") == .unprocessableContent)
            #expect(await client.status(.post, "/devices/ghost/files?name=photo.png", body: "x") == .notFound)
        }
    }

    @Test func `should stage a camera source image or video for a known device`() async throws {
        let devices = routeDevices("router-camera-source")

        try await InProcessServer(devices: devices).test { client in
            let image = try await client.send(
                .post, "/devices/router-camera-source/camera-source?name=still.png", body: "png")
            let video = try await client.send(
                .post, "/simulators/router-camera-source/camera-source?name=clip.mov", body: "mov")

            #expect(image.json["kind"] as? String == "image")
            #expect(video.json["kind"] as? String == "video")
        }
        await CameraSourceStaging.shared.clear(udid: "router-camera-source")
    }

    @Test func `should refuse a camera source that isn't an image or video, or has no device`() async throws {
        try await InProcessServer().test { client in
            #expect(await client.status(.post, "/devices/U/camera-source?name=notes.txt", body: "x")
                == .unsupportedMediaType)
            #expect(await client.status(.post, "/devices/ghost/camera-source?name=still.png", body: "x")
                == .notFound)
        }
    }
}

/// Deep links and the schemes a page suggests, as the router answers them.
@Suite("Serve router: deep links")
struct DeepLinkRouterTests {

    private static func host(failing: Bool = false) -> any Devices {
        let apps = MockApps()
        if failing {
            given(apps).open(.any).willThrow(RoleFailed())
            given(apps).installed().willThrow(RoleFailed())
        } else {
            given(apps).open(.any).willReturn()
            given(apps).installed().willReturn([
                InstalledApp(bundleIdentifier: "com.x.app", name: "Alpha", schemes: ["alpha"]),
            ])
        }
        return routeDevices { $0.register(.apps) { apps } }
    }

    @Test func `should open an app's own link and say it routes to the app`() async throws {
        try await InProcessServer(devices: Self.host()).test { client in
            for path in bothTrees("openurl?url=alpha://home") {
                let response = try await client.send(.post, path)

                #expect(response.status == .ok, "\(path)")
                #expect(response.json["routing"] as? String == "app", "\(path)")
            }
        }
    }

    @Test func `should warn that a web link lands in Safari`() async throws {
        try await InProcessServer(devices: Self.host()).test { client in
            let response = try await client.send(.post, "/devices/U/openurl?url=https://example.com")

            #expect(response.json["routing"] as? String == "browser")
            #expect(response.json["warning"] != nil)
        }
    }

    @Test func `should refuse a link that isn't a URL`() async throws {
        try await InProcessServer(devices: Self.host()).test { client in
            #expect(await client.status(.post, "/devices/U/openurl?url=nope") == .badRequest)
        }
    }

    @Test func `should suggest the schemes installed apps claim`() async throws {
        try await InProcessServer(devices: Self.host()).test { client in
            let response = try await client.send(.get, "/devices/U/schemes.json?q=al")

            #expect((response.json["schemes"] as? [[String: Any]])?.first?["scheme"] as? String == "alpha")
        }
    }

    @Test func `should answer a server error when the link can't open or apps can't be listed`() async throws {
        try await InProcessServer(devices: Self.host(failing: true)).test { client in
            #expect(await client.status(.post, "/devices/U/openurl?url=alpha://x") == .internalServerError)
            #expect(await client.status(.get, "/devices/U/schemes.json") == .internalServerError)
        }
    }

    @Test func `should refuse links on a device that has no apps or doesn't exist`() async throws {
        try await InProcessServer().test { client in
            #expect(await client.status(.post, "/devices/U/openurl?url=alpha://x") == .unprocessableContent)
            #expect(await client.status(.get, "/devices/U/schemes.json") == .unprocessableContent)
            #expect(await client.status(.post, "/devices/ghost/openurl?url=alpha://x") == .notFound)
            #expect(await client.status(.get, "/devices/ghost/schemes.json") == .notFound)
        }
    }
}
