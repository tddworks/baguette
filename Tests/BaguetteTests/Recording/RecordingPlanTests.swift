import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// A recording plan is everything the user asked for — how big, how the
/// frame sits inside that, how fast, how long — resolved against the
/// simulator's own frame the moment the first one arrives.
@Suite("RecordingPlan")
struct RecordingPlanTests {

    private let phone = RenderDimensions(width: 1290, height: 2796)

    private func plan(
        size: CaptureSize,
        fit: CaptureFit = .contain,
        fps: Int = 30,
        duration: Double? = nil
    ) -> RecordingPlan {
        RecordingPlan(
            size: size, fit: fit, background: HexColor("#ffffff"),
            fps: fps, bitrateBps: 8_000_000, duration: duration, format: .mp4
        )
    }

    @Test func `should centre the phone frame on a square canvas when recording square`() throws {
        let placement = plan(size: try CaptureSize.parse("square")).placement(source: phone)

        #expect(placement.width == 2796)
        #expect(placement.height == 2796)
        #expect(placement.drawWidth == 1290)
        #expect(placement.drawHeight == 2796)
        #expect(placement.drawX == 753)
        #expect(placement.drawY == 0)
    }

    @Test func `should use the App Store size regardless of the simulator's own frame size`() throws {
        let placement = plan(size: try CaptureSize.parse("appstore-6.5"))
            .placement(source: RenderDimensions(width: 640, height: 480))

        #expect(placement.width == 1242)
        #expect(placement.height == 2688)
    }

    @Test func `should keep the simulator's own frame size when recording native`() {
        let placement = plan(size: .native).placement(source: phone)

        #expect(placement.width == 1290)
        #expect(placement.height == 2796)
        #expect(placement.isIdentity(for: phone))
    }

    @Test func `should grow an odd canvas to even dimensions so H264 can encode it`() {
        let source = RenderDimensions(width: 1179, height: 2555)
        let placement = plan(size: .native).placement(source: source)

        #expect(placement.width == 1180)
        #expect(placement.height == 2556)
        // The frame keeps its own pixels — it is re-centred, not stretched.
        #expect(placement.drawWidth == 1179)
        #expect(placement.drawHeight == 2555)
        #expect(placement.drawX == 0)
        #expect(placement.drawY == 0)
    }

    @Test func `should spend the extra pixel on the mat, not the frame, when an odd canvas uses contain`() throws {
        // 1000x1001 asked for square → 1001x1001 canvas, grown to 1002x1002.
        let source = RenderDimensions(width: 1000, height: 1001)
        let placement = plan(size: try CaptureSize.parse("square")).placement(source: source)

        #expect(placement.width == 1002)
        #expect(placement.height == 1002)
        // Contain promises the whole frame is visible, so the frame keeps
        // its own pixels and the growth becomes one more row of mat.
        #expect(placement.drawWidth == 1000)
        #expect(placement.drawHeight == 1001)
    }

    @Test func `should still fully cover an odd canvas when using cover`() throws {
        let source = RenderDimensions(width: 1000, height: 1001)
        let placement = plan(size: try CaptureSize.parse("4:3"), fit: .cover)
            .placement(source: source)

        #expect(placement.width == 1336)
        #expect(placement.height == 1002)
        // Cover promises no mat at all — the draw rect grows with the
        // canvas rather than leaving a one-pixel stripe on an edge.
        #expect(placement.drawX <= 0)
        #expect(placement.drawY <= 0)
        #expect(placement.drawX + placement.drawWidth >= placement.width)
        #expect(placement.drawY + placement.drawHeight >= placement.height)
    }

    @Test func `should fill an odd canvas exactly when using stretch`() throws {
        let source = RenderDimensions(width: 1000, height: 1001)
        let placement = plan(size: try CaptureSize.parse("4:3"), fit: .stretch)
            .placement(source: source)

        #expect(placement.drawX == 0)
        #expect(placement.drawY == 0)
        #expect(placement.drawWidth == placement.width)
        #expect(placement.drawHeight == placement.height)
    }

    @Test func `should run until the user stops it when no duration is given`() {
        #expect(plan(size: .native, duration: nil).duration == nil)
        #expect(plan(size: .native, duration: 5).duration == 5)
    }

    @Test func `should clamp a nonsensical frame rate into a recordable one`() {
        #expect(plan(size: .native, fps: 0).fps == 1)
        #expect(plan(size: .native, fps: -4).fps == 1)
        #expect(plan(size: .native, fps: 240).fps == 120)
    }
}
