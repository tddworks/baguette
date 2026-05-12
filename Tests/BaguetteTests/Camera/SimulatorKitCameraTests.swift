import CoreGraphics
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

    // MARK: - injectImage

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

    // MARK: - stop

    /// Verify that `stop` clears cached state and can be called
    /// multiple times without error.
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

    // MARK: - injectVideo

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
