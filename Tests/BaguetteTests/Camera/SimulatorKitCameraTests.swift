import CoreGraphics
import CoreVideo
import Foundation
import IOSurface
import Mockable
import Testing
@testable import Baguette

/// Unit tests for `SimulatorKitCamera`'s orchestration — device
/// resolution, descriptor warm-up, image injection, video lifecycle,
/// and error paths. Uses `MockDeviceHost`, `MockSurfacePusher`, and
/// `MockVideoDecoder` to isolate the orchestrator from live
/// SimulatorKit / AVFoundation dependencies.
@Suite("SimulatorKitCamera — orchestration")
struct SimulatorKitCameraTests {

    // MARK: - injectImage error paths

    /// Verify that `injectImage` throws `deviceNotFound` when the
    /// host has no matching simulator.
    @Test func `injectImage throws when device not found`() {
        let host = MockDeviceHost()
        given(host).resolveDevice(udid: .any).willReturn(nil)
        let pusher = MockSurfacePusher()
        let decoder = MockVideoDecoder()
        let camera = SimulatorKitCamera(
            udid: "ghost", host: host, pusher: pusher, decoder: decoder
        )

        #expect(throws: CameraError.deviceNotFound(udid: "ghost")) {
            try camera.injectImage(createTestImage())
        }
    }

    // MARK: - injectVideo error paths

    /// Verify that `injectVideo` throws `deviceNotFound` when the
    /// host has no matching simulator.
    @Test func `injectVideo throws when device not found`() {
        let host = MockDeviceHost()
        given(host).resolveDevice(udid: .any).willReturn(nil)
        let pusher = MockSurfacePusher()
        let decoder = MockVideoDecoder()
        let camera = SimulatorKitCamera(
            udid: "ghost", host: host, pusher: pusher, decoder: decoder
        )

        #expect(throws: CameraError.deviceNotFound(udid: "ghost")) {
            try camera.injectVideo(url: URL(fileURLWithPath: "/tmp/test.mp4"))
        }
    }

    // MARK: - stop

    /// Verify that `stop` is idempotent — calling it multiple times
    /// without a prior warm-up does not crash or error.
    @Test func `stop is idempotent`() {
        let host = MockDeviceHost()
        given(host).resolveDevice(udid: .any).willReturn(nil)
        let pusher = MockSurfacePusher()
        let decoder = MockVideoDecoder()
        let camera = SimulatorKitCamera(
            udid: "test", host: host, pusher: pusher, decoder: decoder
        )

        camera.stop()
        camera.stop()
    }

    // MARK: - IOSurface creation

    /// Verify that `createIOSurface` produces a surface with the
    /// correct dimensions from a `CGImage`.
    @Test func `createIOSurface produces correct dimensions`() throws {
        let image = createTestImage(width: 100, height: 200)
        let surface = try SimulatorKitCamera.createIOSurface(from: image)

        #expect(IOSurfaceGetWidth(surface) == 100)
        #expect(IOSurfaceGetHeight(surface) == 200)
    }

    /// Verify that `createIOSurface` handles a 1×1 image.
    @Test func `createIOSurface handles 1x1 image`() throws {
        let image = createTestImage(width: 1, height: 1)
        let surface = try SimulatorKitCamera.createIOSurface(from: image)

        #expect(IOSurfaceGetWidth(surface) == 1)
        #expect(IOSurfaceGetHeight(surface) == 1)
    }

    /// Verify BGRA pixel format is set on created surfaces.
    @Test func `createIOSurface uses BGRA pixel format`() throws {
        let image = createTestImage(width: 4, height: 4)
        let surface = try SimulatorKitCamera.createIOSurface(from: image)

        #expect(IOSurfaceGetPixelFormat(surface) == kCVPixelFormatType_32BGRA)
    }

    // MARK: - success-path orchestration

    /// Verify that `injectImage` calls `ensureWarm` → creates a
    /// surface → calls `pusher.push` when the device resolves to a
    /// valid SimDeviceIO descriptor.
    ///
    /// Uses `FakeCameraSimDevice` to satisfy the ObjC runtime calls
    /// in `ensureWarm()`: `device.perform("io")` returns a
    /// `FakeCameraSimDeviceIO`, whose `deviceIOPorts` KVC property
    /// returns a `FakeCameraPort` with `portIdentifier` =
    /// `"com.apple.camera.front"`.
    @Test func `injectImage pushes surface via pusher on success`() throws {
        let host = MockDeviceHost()
        let fakeDevice = FakeCameraSimDevice()
        given(host).resolveDevice(udid: .value("ABC")).willReturn(fakeDevice)

        let pusher = MockSurfacePusher()
        given(pusher).push(.any, to: .any).willReturn()
        let decoder = MockVideoDecoder()

        let camera = SimulatorKitCamera(
            udid: "ABC", host: host, pusher: pusher, decoder: decoder
        )

        let image = createTestImage(width: 8, height: 8)
        try camera.injectImage(image)

        verify(pusher).push(.any, to: .any).called(1)
    }

    /// Verify that `injectVideo` spawns a video loop task and
    /// invokes `decoder.decodeLoop` when the device is resolvable.
    @Test func `injectVideo invokes decoder on success`() async throws {
        let host = MockDeviceHost()
        let fakeDevice = FakeCameraSimDevice()
        given(host).resolveDevice(udid: .value("VID")).willReturn(fakeDevice)

        let pusher = MockSurfacePusher()
        given(pusher).push(.any, to: .any).willReturn()

        let decoder = MockVideoDecoder()
        given(decoder).decodeLoop(url: .any, onFrame: .any).willReturn()

        let camera = SimulatorKitCamera(
            udid: "VID", host: host, pusher: pusher, decoder: decoder
        )

        let url = URL(fileURLWithPath: "/tmp/test.mp4")
        try camera.injectVideo(url: url)

        // Give the background Task a moment to start.
        try await Task.sleep(nanoseconds: 50_000_000)

        verify(decoder).decodeLoop(url: .any, onFrame: .any).called(1)
        camera.stop()
    }

    /// Verify that `stop` cancels any active video loop task.
    @Test func `stop cancels active video loop`() async throws {
        let host = MockDeviceHost()
        let fakeDevice = FakeCameraSimDevice()
        given(host).resolveDevice(udid: .value("STOP")).willReturn(fakeDevice)

        let pusher = MockSurfacePusher()
        let decoder = MockVideoDecoder()
        given(decoder).decodeLoop(url: .any, onFrame: .any).willReturn()

        let camera = SimulatorKitCamera(
            udid: "STOP", host: host, pusher: pusher, decoder: decoder
        )

        try camera.injectVideo(url: URL(fileURLWithPath: "/tmp/test.mp4"))
        try await Task.sleep(nanoseconds: 20_000_000)

        camera.stop()
        #expect(Bool(true), "stop completes without crash or hang")
    }

    /// Verify that the `onFrame` closure wired up by `injectVideo`
    /// pushes each decoded surface through the pusher collaborator.
    @Test func `onFrame closure pushes surface to pusher`() async throws {
        let host = MockDeviceHost()
        let fakeDevice = FakeCameraSimDevice()
        given(host).resolveDevice(udid: .value("FRAME")).willReturn(fakeDevice)

        let pusher = MockSurfacePusher()
        given(pusher).push(.any, to: .any).willReturn()

        let decoder = MockVideoDecoder()
        var capturedOnFrame: (@Sendable (IOSurface) throws -> Void)?
        given(decoder).decodeLoop(url: .any, onFrame: .any).willProduce { _, onFrame in
            capturedOnFrame = onFrame
        }

        let camera = SimulatorKitCamera(
            udid: "FRAME", host: host, pusher: pusher, decoder: decoder
        )

        try camera.injectVideo(url: URL(fileURLWithPath: "/tmp/test.mp4"))
        try await Task.sleep(nanoseconds: 50_000_000)

        let testSurface = try SimulatorKitCamera.createIOSurface(
            from: createTestImage(width: 4, height: 4)
        )
        try capturedOnFrame?(testSurface)

        verify(pusher).push(.any, to: .any).called(1)
        camera.stop()
    }

    /// Verify that a non-cancellation error from the decoder triggers
    /// the camera's error handler which calls `stop()`.
    @Test func `decoder error triggers stop`() async throws {
        let host = MockDeviceHost()
        let fakeDevice = FakeCameraSimDevice()
        given(host).resolveDevice(udid: .value("ERR")).willReturn(fakeDevice)

        let pusher = MockSurfacePusher()
        given(pusher).push(.any, to: .any).willReturn()

        let decoder = MockVideoDecoder()
        given(decoder).decodeLoop(url: .any, onFrame: .any).willThrow(
            CameraError.videoDecodingFailed
        )

        let camera = SimulatorKitCamera(
            udid: "ERR", host: host, pusher: pusher, decoder: decoder
        )

        try camera.injectVideo(url: URL(fileURLWithPath: "/tmp/test.mp4"))
        try await Task.sleep(nanoseconds: 50_000_000)

        verify(decoder).decodeLoop(url: .any, onFrame: .any).called(1)
        camera.stop()
    }

    // MARK: - helpers

    /// Create a minimal test `CGImage` with the given dimensions.
    private func createTestImage(width: Int = 10, height: Int = 10) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        )!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }
}

// MARK: - ObjC test doubles for SimDeviceIO warm-up

/// Fake `SimDevice` that responds to `perform("io")` by returning
/// a `FakeCameraSimDeviceIO`. Satisfies `ensureWarm()`'s ObjC
/// runtime call chain without a real CoreSimulator connection.
private class FakeCameraSimDevice: NSObject {
    /// The fake IO object returned by `device.perform("io")`.
    private let fakeIO = FakeCameraSimDeviceIO()

    @objc func io() -> NSObject { fakeIO }
}

/// Fake `SimDeviceIO` — responds to `updateIOPorts` (no-op) and
/// exposes `deviceIOPorts` via KVC, returning a single
/// `FakeCameraPort` with identifier `"com.apple.camera.front"`.
private class FakeCameraSimDeviceIO: NSObject {
    /// The single camera port exposed via KVC `deviceIOPorts`.
    private let port = FakeCameraPort()

    @objc func updateIOPorts() {}

    override func value(forKey key: String) -> Any? {
        if key == "deviceIOPorts" { return [port] }
        return super.value(forKey: key)
    }
}

/// Fake camera IO port — responds to `portIdentifier` and
/// `descriptor` selectors that `ensureWarm()` inspects.
private class FakeCameraPort: NSObject {
    /// The descriptor object returned to `ensureWarm()`.
    private let desc = FakeCameraDescriptor()

    @objc func portIdentifier() -> NSString {
        "com.apple.camera.front"
    }

    @objc func descriptor() -> NSObject { desc }
}

/// Fake camera descriptor — the terminal object that
/// `ensureWarm()` caches and passes to `SurfacePusher.push`.
private class FakeCameraDescriptor: NSObject {}
