import Testing
import CoreGraphics
@testable import BaguetteCore

/// `AXFrameTransform` projects mac-window-coordinate CGRects from
/// AXPTranslator into device-point CGRects (the same units the
/// gesture wire uses). Width-uniform scale + vertical centering
/// offset matches Simulator.app's letterbox layout for tall
/// devices in a short window.
@Suite("AXFrameTransform")
struct AXFrameTransformTests {

    // MARK: - happy path: square mapping (rootFrame matches device aspect)

    @Test func `1:1 root → identity scale, no y-offset`() {
        let t = AXFrameTransform(
            rootFrame: CGRect(x: 0, y: 0, width: 393, height: 852),
            pointSize: CGSize(width: 393, height: 852)
        )
        let mapped = t.map(CGRect(x: 100, y: 200, width: 50, height: 60))
        #expect(mapped == CGRect(x: 100, y: 200, width: 50, height: 60))
    }

    @Test func `2:1 root → halves coordinates uniformly`() {
        let t = AXFrameTransform(
            rootFrame: CGRect(x: 0, y: 0, width: 786, height: 1704),
            pointSize: CGSize(width: 393, height: 852)
        )
        let mapped = t.map(CGRect(x: 200, y: 400, width: 100, height: 80))
        #expect(mapped == CGRect(x: 100, y: 200, width: 50, height: 40))
    }

    // MARK: - origin offset: rootFrame moved away from (0,0)

    @Test func `non-zero root origin shifts the mapped origin back to device-space`() {
        let t = AXFrameTransform(
            rootFrame: CGRect(x: 50, y: 80, width: 393, height: 852),
            pointSize: CGSize(width: 393, height: 852)
        )
        let mapped = t.map(CGRect(x: 60, y: 90, width: 30, height: 30))
        #expect(mapped == CGRect(x: 10, y: 10, width: 30, height: 30))
    }

    // MARK: - letterbox: rootFrame is wider than device, leaves vertical slack

    @Test func `wider-than-tall root injects a positive y centering offset`() {
        // pointSize is 100x200 (1:2 portrait); rootFrame is 100 wide
        // and 100 tall. Width-scale = 1; the device's logical 200 height
        // exceeds rootFrame.height * scale (100), leaving 100pt of
        // slack split evenly above + below → +50 on every y.
        let t = AXFrameTransform(
            rootFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            pointSize: CGSize(width: 100, height: 200)
        )
        let mapped = t.map(CGRect(x: 10, y: 20, width: 30, height: 40))
        #expect(mapped == CGRect(x: 10, y: 70, width: 30, height: 40))
    }

    // MARK: - degenerate inputs → identity (don't divide by zero)

    @Test func `zero-width root falls back to identity`() {
        let t = AXFrameTransform(
            rootFrame: CGRect(x: 0, y: 0, width: 0, height: 100),
            pointSize: CGSize(width: 100, height: 100)
        )
        let input = CGRect(x: 5, y: 6, width: 7, height: 8)
        #expect(t.map(input) == input)
    }

    @Test func `zero-height root falls back to identity`() {
        let t = AXFrameTransform(
            rootFrame: CGRect(x: 0, y: 0, width: 100, height: 0),
            pointSize: CGSize(width: 100, height: 100)
        )
        let input = CGRect(x: 5, y: 6, width: 7, height: 8)
        #expect(t.map(input) == input)
    }

    @Test func `zero-width pointSize falls back to identity`() {
        let t = AXFrameTransform(
            rootFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            pointSize: CGSize(width: 0, height: 100)
        )
        let input = CGRect(x: 5, y: 6, width: 7, height: 8)
        #expect(t.map(input) == input)
    }

    @Test func `zero-height pointSize falls back to identity`() {
        let t = AXFrameTransform(
            rootFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            pointSize: CGSize(width: 100, height: 0)
        )
        let input = CGRect(x: 5, y: 6, width: 7, height: 8)
        #expect(t.map(input) == input)
    }

    // MARK: - unmap: device-point → mac-host coordinate, the inverse
    // path used by the AXP server-side hit-test.

    @Test func `unmap is the inverse of map for the identity transform`() {
        let t = AXFrameTransform(
            rootFrame: CGRect(x: 0, y: 0, width: 393, height: 852),
            pointSize: CGSize(width: 393, height: 852)
        )
        #expect(t.unmap(CGPoint(x: 100, y: 200)) == CGPoint(x: 100, y: 200))
    }

    @Test func `unmap reverses a 2:1 down-scale into an up-scale`() {
        let t = AXFrameTransform(
            rootFrame: CGRect(x: 0, y: 0, width: 786, height: 1704),
            pointSize: CGSize(width: 393, height: 852)
        )
        // device (100, 200) corresponds to host (200, 400) — exactly
        // reversing the `2:1 root → halves coordinates uniformly` map.
        #expect(t.unmap(CGPoint(x: 100, y: 200)) == CGPoint(x: 200, y: 400))
    }

    @Test func `unmap reverses a non-zero root origin shift`() {
        let t = AXFrameTransform(
            rootFrame: CGRect(x: 50, y: 80, width: 393, height: 852),
            pointSize: CGSize(width: 393, height: 852)
        )
        // device (10, 10) → host (60, 90), inverse of the existing
        // map-side origin-shift test.
        #expect(t.unmap(CGPoint(x: 10, y: 10)) == CGPoint(x: 60, y: 90))
    }

    @Test func `unmap reverses the letterbox y-offset`() {
        // Same letterbox setup as the map test: pointSize 100x200,
        // rootFrame 100x100 → +50 y centering offset.
        let t = AXFrameTransform(
            rootFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            pointSize: CGSize(width: 100, height: 200)
        )
        // device (10, 70) → host (10, 20), inverse of the map test
        // mapping (10, 20) → (10, 70).
        #expect(t.unmap(CGPoint(x: 10, y: 70)) == CGPoint(x: 10, y: 20))
    }

    @Test func `unmap falls back to identity on degenerate inputs`() {
        let zeroRoot = AXFrameTransform(
            rootFrame: CGRect(x: 0, y: 0, width: 0, height: 100),
            pointSize: CGSize(width: 100, height: 100)
        )
        #expect(zeroRoot.unmap(CGPoint(x: 5, y: 6)) == CGPoint(x: 5, y: 6))

        let zeroPoint = AXFrameTransform(
            rootFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            pointSize: CGSize(width: 100, height: 0)
        )
        #expect(zeroPoint.unmap(CGPoint(x: 5, y: 6)) == CGPoint(x: 5, y: 6))
    }
}
