import Foundation
import Hummingbird
import HummingbirdWebSocket
import NIOCore
@_spi(WSInternal) import WSCore

extension Server {
    /// Register the `/simulators/:udid/camera` WebSocket route — the
    /// browser's camera picker drives this. One WS owns the host frame
    /// buffer. Closing stops capture and removes the dylib's launchd
    /// env on successful cleanup. Failed cleanup remains recoverable by
    /// reconnecting to the same device and explicitly stopping again.
    func registerCameraRoute(on router: Router<BasicWebSocketRequestContext>) {
        let simulators = self.simulators
        let sessions = self.cameraSessions
        let bindHost = self.host
        let bindPort = self.port
        let allowedHosts = self.allowedHosts
        let trustedWebSocketUpgrade:
            @Sendable (Request, BasicWebSocketRequestContext) async throws -> RouterShouldUpgrade = {
                request, _ in
                Self.isTrustedBrowserRequest(
                    request, bindHost: bindHost, bindPort: bindPort, allowedHosts: allowedHosts
                ) ? .upgrade([:]) : .dontUpgrade
            }
        router.ws(
            "/simulators/:udid/camera",
            shouldUpgrade: trustedWebSocketUpgrade
        ) { inbound, outbound, context in
            await Self.cameraWS(
                udid: Self.udidParam(context.request),
                simulators: simulators,
                sessions: sessions,
                inbound: inbound,
                outbound: outbound
            )
        }
    }

    /// One WS lifecycle. On connect: push the device list. Then read
    /// JSON messages forever, dispatching to the server-owned
    /// `CameraSession`. The session writes BGRA frames into
    /// `/tmp/SimCam.bgra` (the path the VirtualCamera dylib reads);
    /// `VirtualCameraInstaller` resolves the bundled dylib's
    /// per-hash dest path, and `SimctlSimulatorInjection` arms the
    /// simulator's launchd env to point at it.
    @MainActor
    private static func cameraWS(
        udid: String,
        simulators: any Simulators,
        sessions: CameraSessions,
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter
    ) async {
        guard !udid.isEmpty, let sim = simulators.find(udid: udid) else {
            try? await outbound.write(
                .text(
                    #"{"type":"camera_state","ok":false,"error":"unknown udid"}"#
                ))
            return
        }
        let cameras = AVCameras()
        let session: CameraSession
        do {
            session = try sessions.connect(udid: udid) {
                CameraSession(
                    webcam: AVCameraCapture(),
                    image: ImageFileCapture(),
                    video: VideoFileCapture(),
                    sink: try SharedMemoryFrameSink(path: "/tmp/SimCam.bgra"),
                    injection: SimctlSimulatorInjection(),
                    guestTerminated: sessions.guestTerminated
                )
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            try? await outbound.write(
                .text(
                    #"{"type":"camera_state","ok":false,"error":"\#(jsonEscape(message))"}"#
                ))
            return
        }

        // Push the initial device list so the picker can render
        // immediately without an extra round-trip.
        await sendDeviceList(cameras: cameras, outbound: outbound)
        await sendCameraState(session: session, outbound: outbound)

        // 1-Hz heartbeat: sample FPS off the frame counter and push
        // `camera_state` so the browser's "streaming · X fps" readout
        // updates while frames flow. Detached child task — cancelled
        // during teardown below.
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                session.sampleFPS()
                if case .streaming = session.phase {
                    await sendCameraState(session: session, outbound: outbound)
                }
            }
        }

        do {
            for try await frame in inbound {
                guard frame.opcode == .text else { continue }
                let line = String(buffer: frame.data)
                await handleCameraLine(
                    line: line,
                    cameras: cameras,
                    session: session,
                    sim: sim,
                    outbound: outbound
                )
            }
        } catch {
            // socket closed; teardown below
        }

        // Teardown, explicitly ordered rather than deferred. `stop()`
        // disarms DYLD_INSERT_LIBRARIES on this sim, so it has to be
        // *awaited* here: fired into a detached task it could land after
        // a reconnecting socket armed the next session and disarm that
        // one instead. Capture must also stop before the staged file is
        // dropped, which is the reverse of what LIFO defers gave us.
        heartbeat.cancel()
        await sessions.disconnect(session)
        if let error = session.lastError {
            log("[camera] \(error)")
        }
        // Drop any uploaded image/video source when the socket closes so
        // a stale file can't leak into the next session.
        await CameraSourceStaging.shared.clear(udid: udid)
    }

    @MainActor
    private static func handleCameraLine(
        line: String,
        cameras: any Cameras,
        session: CameraSession,
        sim: any Simulator,
        outbound: WebSocketOutboundWriter
    ) async {
        guard let data = line.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return
        }
        let requestId = dict["requestId"] as? String
        let msg: CameraMessage
        do { msg = try CameraMessage.parse(dict) } catch {
            await sendCameraState(
                session: session, outbound: outbound,
                requestId: requestId, error: String(describing: error))
            return
        }

        switch msg {
        case .list:
            await sendDeviceList(cameras: cameras, outbound: outbound, requestId: requestId)
        case .start(let startSource, let flags):
            session.setFlags(flags)
            let source: CameraSource
            switch startSource {
            case .webcam(let uid):
                let devices = await cameras.available()
                guard devices.contains(where: { $0.uid == uid }) else {
                    await sendCameraState(
                        session: session, outbound: outbound,
                        requestId: requestId, error: "unknown camera deviceUID")
                    return
                }
                source = .device(uid: uid)
            case .image, .video:
                guard let path = CameraSourceStaging.shared.path(udid: sim.udid) else {
                    await sendCameraState(
                        session: session, outbound: outbound,
                        requestId: requestId,
                        error: "no file uploaded — drop an image or video on the camera card first")
                    return
                }
                // Guard against a start that names a different kind than
                // the staged file (e.g. an image staged, "video" started).
                let stagedKind = CameraMediaKind.at(URL(fileURLWithPath: path))
                let wantImage = (startSource == .image)
                guard stagedKind == (wantImage ? .image : .video) else {
                    await sendCameraState(
                        session: session, outbound: outbound,
                        requestId: requestId, error: "the uploaded file doesn't match the selected source kind")
                    return
                }
                source = wantImage ? .image(path: path) : .video(path: path)
            }
            guard let dylibPath = InjectedDylibInstaller.installIfNeeded(.camera) else {
                await sendCameraState(
                    session: session, outbound: outbound,
                    requestId: requestId, error: "VirtualCamera.dylib is not bundled in this build")
                return
            }
            await session.start(source: source, on: sim, dylibPath: dylibPath)
            await sendCameraState(session: session, outbound: outbound, requestId: requestId)
        case .stop:
            guard let dylibPath = InjectedDylibInstaller.installIfNeeded(.camera) else {
                await sendCameraState(
                    session: session, outbound: outbound,
                    requestId: requestId, error: "VirtualCamera.dylib is not bundled in this build")
                return
            }
            await session.stop(on: sim, dylibPath: dylibPath)
            await sendCameraState(session: session, outbound: outbound, requestId: requestId)
        case .setFlags(let flags):
            session.setFlags(flags)
            await sendCameraState(session: session, outbound: outbound, requestId: requestId)
        }
    }

    @MainActor
    private static func sendDeviceList(
        cameras: any Cameras,
        outbound: WebSocketOutboundWriter,
        requestId: String? = nil
    ) async {
        let devices = await cameras.available()
        let arr = devices.map { $0.wireDictionary }
        var payload: [String: Any] = ["type": "camera_devices", "devices": arr]
        if let requestId { payload["requestId"] = requestId }
        if let bytes = try? JSONSerialization.data(withJSONObject: payload),
            let json = String(data: bytes, encoding: .utf8)
        {
            try? await outbound.write(.text(json))
        }
    }

    @MainActor
    private static func sendCameraState(
        session: CameraSession,
        outbound: WebSocketOutboundWriter,
        requestId: String? = nil,
        error: String? = nil
    ) async {
        do {
            try await outbound.write(.text(try cameraStateJSON(session, requestId: requestId, error: error)))
        } catch {
            log("[camera] could not deliver state: \(error)")
        }
    }

    @MainActor
    static func cameraStateJSON(
        _ session: CameraSession, requestId: String? = nil, error: String? = nil
    ) throws -> String {
        let phase: String
        var sourceKind: String? = nil
        var deviceUID: String? = nil
        if case .streaming(let source) = session.phase {
            phase = "streaming"
            sourceKind = source.wireKind
            if case .device(let uid) = source { deviceUID = uid }
        } else {
            phase = "idle"
        }
        var payload: [String: Any] = [
            "type": "camera_state",
            "ok": error == nil && session.lastError == nil,
            "phase": phase,
            "fps": session.fps,
            "cleanupRequired": session.cleanupRequired,
        ]
        if let kind = sourceKind { payload["source"] = kind }
        if let uid = deviceUID { payload["device"] = uid }
        if let err = error ?? session.lastError { payload["error"] = err }
        if let requestId { payload["requestId"] = requestId }
        return String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    }

}
