import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// What a page drops onto a device — apps, media, a camera source — for any
/// device, through `Devices`, under `/devices/:udid/…` and a simulator's
/// old `/simulators/:udid/…`.
extension Server {

    func registerFileRoutes(
        on router: Router<BasicWebSocketRequestContext>,
        rejectUntrustedBrowser: @escaping @Sendable (Request) -> Response?
    ) {
        let devices = allDevices

        // File upload — drag-and-drop a file onto the device view. One
        // dumb entry point: the browser POSTs raw bytes with `?name=`,
        // and `Server.addFile` routes by extension to the right device
        // collection (apps → install, media → Photos). Anything with no
        // home on a simulator is refused with 415, never swallowed.
        //
        // Browser-only. Because it classifies by extension, the
        // authority it confers would depend on the bytes — so it is the
        // one upload route `PluginRoute` maps to nothing. Plugins use
        // `/apps` and `/media` below, which say which power they mean.
        for path in Self.deviceRoutes("files") {
            router.post(RouterPath(path)) { r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                return await Self.handleUpload(r, devices: devices, allowing: .all)
            }
        }

        // The two narrow halves, each guarded by its own capability.
        // Same plumbing, different answer to "what may land here".
        for path in Self.deviceRoutes("apps") {
            router.post(RouterPath(path)) { r, _ in
                if Self.presentsGrant(r) == false, let rejected = rejectUntrustedBrowser(r) {
                    return rejected
                }
                return await Self.handleUpload(r, devices: devices, allowing: .apps)
            }
        }

        for path in Self.deviceRoutes("media") {
            router.post(RouterPath(path)) { r, _ in
                if Self.presentsGrant(r) == false, let rejected = rejectUntrustedBrowser(r) {
                    return rejected
                }
                return await Self.handleUpload(r, devices: devices, allowing: .media)
            }
        }

        // Camera source upload: an image / video the simulator's camera
        // streams from. Unlike /files (consumed synchronously by simctl
        // inside the request), these bytes must OUTLIVE the POST — the
        // camera WebSocket streams them later — so they're staged into a
        // persistent per-udid slot and remembered by CameraSourceStaging.
        for path in Self.deviceRoutes("camera-source") {
            router.post(RouterPath(path)) { r, _ in
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
                let udid = Self.udidParam(r)
                // Resolve the udid against a real device before it names a
                // directory — `udidParam` percent-decodes, so an unchecked
                // udid can carry `..` into the staging root. `CameraSourceSlot`
                // refuses those too; this is the same check `/files` makes and
                // it keeps the error honest ("unknown udid" beats a slot error).
                guard !udid.isEmpty, (try? devices.find(id: DeviceID(udid))) ?? nil != nil else {
                    return Self.pluginError("unknown udid: \(udid)", status: .notFound)
                }
                let rawName = String(r.uri.queryParameters.get("name") ?? "source")
                let filename = (rawName as NSString).lastPathComponent
                let nameURL = URL(fileURLWithPath: filename)

                // Cheap reject before reading the body: only images/videos
                // can drive the camera.
                guard let kind = CameraMediaKind.at(nameURL) else {
                    return Self.pluginError(
                        "no camera source for .\(nameURL.pathExtension) (images and videos only)",
                        status: .unsupportedMediaType
                    )
                }
                guard let buffer = try? await r.body.collect(upTo: Self.maxUploadBytes) else {
                    return Self.pluginError("upload too large (max \(Self.maxUploadBytes / (1 << 20)) MiB) or unreadable", status: .badRequest)
                }
                do {
                    try await CameraSourceStaging.shared.stage(
                        udid: udid, filename: filename, data: Data(buffer: buffer)
                    )
                } catch {
                    return Self.pluginError("could not stage camera source: \(error)", status: .internalServerError)
                }
                let json = "{\"ok\":true,\"kind\":\"\(kind == .image ? "image" : "video")\"}"
                return Response(status: .ok, headers: [.contentType: "application/json"],
                                body: .init(byteBuffer: ByteBuffer(string: json)))
            }
        }

    }

    /// Upper bound on a single drag-and-drop upload, collected into
    /// memory before staging to a temp file. 1 GiB comfortably covers
    /// `.ipa` apps and media clips; this is a localhost dev tool, so a
    /// generous cap is fine.
    static let maxUploadBytes = 1 << 30

    /// Outcome of `POST …/files`.
    enum AddFileOutcome: Equatable {
        case installed              // an app → simctl install
        case added                  // media → simctl addmedia
        case unsupported(ext: String)
        /// The file has a home on a simulator, just not through *this*
        /// route — an app posted to `/media`, or a photo to `/apps`.
        /// Distinct from `.unsupported` because the fix is different:
        /// use the other endpoint, don't convert the file.
        case wrongKind(ext: String)
        case badArchive(reason: String)   // a zip that isn't a packed .app
        case unknownDevice
        /// The device can't take this kind of file.
        case refused(DeviceError)
        case dispatchFailed
    }

    /// Pure dispatch for `POST …/files`. The thin
    /// "which collection?" router: classify the already-materialised
    /// file by extension and hand it to the matching device collection.
    /// A file with no home on a simulator is refused (`.unsupported`)
    /// rather than silently dropped. Split from the route closure so
    /// unit tests drive every branch with `MockSimulators` + `MockApps`
    /// / `MockPhotoLibrary`.
    /// The upload plumbing `/files`, `/apps` and `/media` share:
    /// sanitise the client-supplied name, reject an extension with no
    /// home *before* reading megabytes, stage into a unique temp dir,
    /// dispatch, then clean up whatever happened.
    ///
    /// Only `allowing` differs between the three, which is the point —
    /// the routes are the same act under different authority, so they
    /// should not be three copies that can drift apart.
    static func handleUpload(
        _ r: Request, devices: any Devices, allowing kinds: UploadKinds
    ) async -> Response {
        let udid = Self.udidParam(r)
        // Strip any path components from the client-supplied name so
        // `?name=../../etc/x` can't escape the temp directory.
        let rawName = String(r.uri.queryParameters.get("name") ?? "upload")
        let filename = (rawName as NSString).lastPathComponent
        let nameURL = URL(fileURLWithPath: filename)

        // Cheap reject before reading the body: if the extension has no
        // home on a simulator — or no home on *this* route — don't
        // bother uploading megabytes to find out.
        let isApp = AppBundle.at(nameURL) != nil || AppArchive.at(nameURL) != nil
        let isMedia = MediaItem.at(nameURL) != nil
        guard isApp || isMedia else {
            return pluginError(
                "no home for .\(nameURL.pathExtension) on a simulator (apps, zipped apps, and media only)",
                status: .unsupportedMediaType
            )
        }
        guard (isApp && kinds.contains(.apps)) || (isMedia && kinds.contains(.media)) else {
            return pluginError(Self.wrongKindMessage(ext: nameURL.pathExtension.lowercased(), allowed: kinds),
                             status: .unsupportedMediaType)
        }
        guard let buffer = try? await r.body.collect(upTo: Self.maxUploadBytes) else {
            return pluginError("upload too large (max \(Self.maxUploadBytes / (1 << 20)) MiB) or unreadable", status: .badRequest)
        }

        // Materialise into a unique temp dir (preserving the name so
        // the extension — and simctl's bundle detection — survives),
        // dispatch, then clean up regardless of outcome.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("baguette-upload-\(UUID().uuidString)")
        let tempURL = dir.appendingPathComponent(filename)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(buffer: buffer).write(to: tempURL)
        } catch {
            return pluginError("could not stage upload: \(error)", status: .internalServerError)
        }

        switch await Self.addFile(udid: udid, path: tempURL, devices: devices, allowing: kinds) {
        case .installed:
            return Response(status: .ok, headers: [.contentType: "application/json"],
                            body: .init(byteBuffer: ByteBuffer(string: "{\"ok\":true,\"kind\":\"app\"}")))
        case .added:
            return Response(status: .ok, headers: [.contentType: "application/json"],
                            body: .init(byteBuffer: ByteBuffer(string: "{\"ok\":true,\"kind\":\"media\"}")))
        case .unsupported(let ext):
            return pluginError("no home for .\(ext) on a simulator (apps, zipped apps, and media only)", status: .unsupportedMediaType)
        case .wrongKind(let ext):
            return pluginError(Self.wrongKindMessage(ext: ext, allowed: kinds), status: .unsupportedMediaType)
        case .badArchive(let reason):
            return pluginError(reason, status: .unsupportedMediaType)
        case .unknownDevice:
            return pluginError("unknown udid: \(udid)", status: .notFound)
        case .refused(let refusal):
            return Self.refusal(refusal)
        case .dispatchFailed:
            return pluginError("file upload failed (simctl error — is the device booted?)", status: .internalServerError)
        }
    }

    /// Names the endpoint that *would* have taken it, so the fix is
    /// obvious rather than "415, good luck".
    static func wrongKindMessage(ext: String, allowed: UploadKinds) -> String {
        allowed.contains(.apps)
            ? ".\(ext) is media, not an app — POST it to /media"
            : ".\(ext) is an app, not media — POST it to /apps"
    }

    static func addFile(
        udid: String,
        path: URL,
        devices: any Devices,
        allowing kinds: UploadKinds = .all
    ) async -> AddFileOutcome {
        guard !udid.isEmpty, (try? devices.find(id: DeviceID(udid))) ?? nil != nil else {
            return .unknownDevice
        }
        do {
            if let app = AppBundle.at(path) {
                guard kinds.contains(.apps) else { return .wrongKind(ext: path.pathExtension.lowercased()) }
                switch role(.apps, of: udid, in: devices) {
                case .unknownDevice: return .unknownDevice
                case .refused(let refusal): return .refused(refusal)
                case .role(let apps): try await apps.install(app)
                }
                return .installed
            }
            if let archive = AppArchive.at(path) {
                guard kinds.contains(.apps) else { return .wrongKind(ext: path.pathExtension.lowercased()) }
                switch role(.apps, of: udid, in: devices) {
                case .unknownDevice: return .unknownDevice
                case .refused(let refusal): return .refused(refusal)
                case .role(let apps): try await apps.install(archive: archive)
                }
                return .installed
            }
            if let media = MediaItem.at(path) {
                guard kinds.contains(.media) else { return .wrongKind(ext: path.pathExtension.lowercased()) }
                switch role(.photos, of: udid, in: devices) {
                case .unknownDevice: return .unknownDevice
                case .refused(let refusal): return .refused(refusal)
                case .role(let photos): try await photos.add(media)
                }
                return .added
            }
            return .unsupported(ext: path.pathExtension.lowercased())
        } catch let error as AppsError {
            // Extraction / locating failures are the upload's fault —
            // surface the reason instead of a generic simctl 500.
            switch error {
            case .extractFailed, .archiveTooLarge, .noAppInArchive:
                return .badArchive(reason: error.description)
            // `openFailed` / `listFailed` / the lifecycle cases can't reach an upload, but the
            // switch has to name them: the compiler is the only thing
            // that will notice when a new `AppsError` case does.
            case .installFailed, .openFailed, .deliverFailed, .notificationsNotAllowed, .listFailed, .terminateFailed, .launchFailed:
                return .dispatchFailed
            }
        } catch {
            return .dispatchFailed
        }
    }

}
