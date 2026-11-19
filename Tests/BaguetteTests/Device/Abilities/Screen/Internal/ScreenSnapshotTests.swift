import CoreGraphics
import CoreVideo
import Foundation
import IOSurface
import ImageIO
import Mockable
import Testing

@testable import Baguette
@testable import BaguetteDevice

/// The SimulatorKit call that hands over a framebuffer is integration-
/// only, but everything `ScreenSnapshot` does around it is not: the
/// single-shot race between the frame callback, the timeout timer, and a
/// throwing `start`, plus the size / fit / format the caller asked for.
/// `MockScreen` stands in for the simulator and a host-allocated
/// `IOSurface` stands in for the framebuffer.
@Suite("ScreenSnapshot")
struct ScreenSnapshotTests {

    @Test func `should describe the capture geometry as the even scaled frame actually encoded`() async throws {
        let surface = try #require(makeSurface(width: 1206, height: 2622))
        let screen = MockScreen()
        given(screen).start(onFrame: .any).willProduce { onFrame in onFrame(surface) }
        given(screen).stop().willReturn(())

        let frame = try await ScreenSnapshot.captureWithGeometry(screen: screen, scale: 2, format: .png)

        #expect(frame.geometry.framebufferPixels == RenderDimensions(width: 1206, height: 2622))
        #expect(frame.geometry.scaledPixels == RenderDimensions(width: 604, height: 1312))
        #expect(try decoded(frame.bytes) == CGSize(width: 604, height: 1312))
        #expect(
            frame.geometry.placement
                == CapturePlacement(
                    width: 604, height: 1312, drawX: 0, drawY: 0, drawWidth: 604, drawHeight: 1312
                ))
        verify(screen).stop().called(1)
    }

    @Test(arguments: [CaptureFit.contain, .cover, .stretch])
    func `should describe exactly the letterbox, crop or stretch encoded into the capture`(fit: CaptureFit) async throws {
        let surface = try #require(makeSurface(width: 120, height: 60))
        let screen = MockScreen()
        given(screen).start(onFrame: .any).willProduce { onFrame in onFrame(surface) }
        given(screen).stop().willReturn(())

        let frame = try await ScreenSnapshot.captureWithGeometry(
            screen: screen, size: try CaptureSize.parse("40x80"), fit: fit, format: .png
        )

        let expected: CapturePlacement
        switch fit {
        case .contain:
            expected = CapturePlacement(width: 40, height: 80, drawX: 0, drawY: 30, drawWidth: 40, drawHeight: 20)
        case .cover:
            expected = CapturePlacement(width: 40, height: 80, drawX: -60, drawY: 0, drawWidth: 160, drawHeight: 80)
        case .stretch:
            expected = CapturePlacement(width: 40, height: 80, drawX: 0, drawY: 0, drawWidth: 40, drawHeight: 80)
        }
        #expect(frame.geometry.placement == expected)
        #expect(frame.geometry.framebufferPixels == RenderDimensions(width: 120, height: 60))
        #expect(try decoded(frame.bytes) == CGSize(width: expected.width, height: expected.height))
        let json = frame.geometry.json
        #expect(json["imagePixels"] as? [String: Int] == ["width": 40, "height": 80])
        #expect(
            json["drawRectPixels"] as? [String: Int] == [
                "x": expected.drawX, "y": expected.drawY,
                "width": expected.drawWidth, "height": expected.drawHeight,
            ])
    }

    @Test func `should still release the screen when encoding the capture fails`() async throws {
        let surface = try #require(makeSurface(width: 120, height: 60))
        let screen = MockScreen()
        given(screen).start(onFrame: .any).willProduce { onFrame in onFrame(surface) }
        given(screen).stop().willReturn(())

        await #expect(throws: ScreenSnapshot.Failure.encodeFailed) {
            _ = try await ScreenSnapshot.captureWithGeometry(
                screen: screen,
                size: CaptureSize(
                    spec: "invalid", label: "Invalid", kind: .fixed(RenderDimensions(width: 0, height: 0)))
            )
        }
        verify(screen).stop().called(1)
    }

    @Test func `should capture a frame as JPEG at the screen's own size`() async throws {
        let surface = try #require(makeSurface(width: 120, height: 60))
        let screen = MockScreen()
        given(screen).start(onFrame: .any).willProduce { onFrame in onFrame(surface) }
        given(screen).stop().willReturn(())

        let bytes = try await ScreenSnapshot.capture(screen: screen)

        #expect(bytes.prefix(2) == Data([0xFF, 0xD8]))
        #expect(try decoded(bytes) == CGSize(width: 120, height: 60))
    }

    @Test func `should resize the captured frame when a size is requested`() async throws {
        let surface = try #require(makeSurface(width: 120, height: 60))
        let screen = MockScreen()
        given(screen).start(onFrame: .any).willProduce { onFrame in onFrame(surface) }
        given(screen).stop().willReturn(())

        let bytes = try await ScreenSnapshot.capture(
            screen: screen,
            size: try CaptureSize.parse("40x80"), fit: .contain, background: "#000000"
        )

        #expect(try decoded(bytes) == CGSize(width: 40, height: 80))
    }

    @Test func `should capture a real PNG when PNG is asked for`() async throws {
        let surface = try #require(makeSurface(width: 40, height: 20))
        let screen = MockScreen()
        given(screen).start(onFrame: .any).willProduce { onFrame in onFrame(surface) }
        given(screen).stop().willReturn(())

        let bytes = try await ScreenSnapshot.capture(screen: screen, format: .png)

        #expect(bytes.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    }

    @Test func `should time out and release the screen when it never delivers a frame`() async throws {
        let screen = MockScreen()
        given(screen).start(onFrame: .any).willReturn(())
        given(screen).stop().willReturn(())

        await #expect(throws: ScreenSnapshot.Failure.timeout) {
            _ = try await ScreenSnapshot.capture(screen: screen, timeout: 0.05)
        }
        verify(screen).stop().called(1)
    }

    @Test func `should report the screen's own error and release it when it refuses to open`() async throws {
        let screen = MockScreen()
        given(screen).start(onFrame: .any).willThrow(SnapshotTestError.notBooted)
        given(screen).stop().willReturn(())

        await #expect(throws: SnapshotTestError.notBooted) {
            _ = try await ScreenSnapshot.capture(screen: screen)
        }
        verify(screen).stop().called(1)
    }
}

private enum SnapshotTestError: Error, Equatable { case notBooted }

/// A host-allocated BGRA surface — same shape as the one SimulatorKit
/// hands over, without needing a booted simulator.
private func makeSurface(width: Int, height: Int) -> IOSurface? {
    IOSurface(properties: [
        .width: width,
        .height: height,
        .bytesPerElement: 4,
        .bytesPerRow: width * 4,
        .pixelFormat: kCVPixelFormatType_32BGRA,
        .allocSize: width * height * 4,
    ])
}

private func decoded(_ data: Data) throws -> CGSize {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    return CGSize(width: image.width, height: image.height)
}
