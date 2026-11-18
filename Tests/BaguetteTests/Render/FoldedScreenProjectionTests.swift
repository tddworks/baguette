import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDevice

// Where a foldable's lit screen lands in the rendered image, so a click
// can be mapped back onto it. The unfolded screen bends at the hinge,
// so it is two flat pieces; the cover is one, on the back of the leaf
// that folds over. Every piece's corners are named in the framebuffer's
// own order — the guest draws the open pose landscape into a portrait
// buffer — and carries the part of the buffer it shows, so the browser
// needs no orientation of its own.
@Suite("FoldedScreenProjection")
struct FoldedScreenProjectionTests {
    let fold = DeviceModelFold(
        clip: "l_over_r", shutTime: 5, coverMaterial: "cover",
        coverTextureSize: RenderDimensions(width: 1, height: 1), openPoseDegrees: 130
    )
    // Rest frame: flat, facing the camera at +z; the hinge is the y axis.
    let inner = ScreenLocalCorners(
        topLeft: Vector3(x: -2, y: 1, z: 0), topRight: Vector3(x: 2, y: 1, z: 0),
        bottomRight: Vector3(x: 2, y: -1, z: 0), bottomLeft: Vector3(x: -2, y: -1, z: 0)
    )
    // The cover: the back of the left half, seen through the device.
    let cover = ScreenLocalCorners(
        topLeft: Vector3(x: -2, y: 1, z: -0.01), topRight: Vector3(x: 0, y: 1, z: -0.01),
        bottomRight: Vector3(x: 0, y: -1, z: -0.01), bottomLeft: Vector3(x: -2, y: -1, z: -0.01)
    )
    // A 90° lens ten units away: u = (x/depth + 1) / 2, v = (1 − y/depth) / 2.
    let camera = (distance: 10.0, fov: 90.0, aspect: 1.0)

    func pieces(_ degrees: Double, lit: IntegratedPanel, orientation: DeviceOrientation) -> [ScreenPiece] {
        FoldedScreenProjection.pieces(
            inner: inner, cover: cover, litPanel: lit, orientation: orientation,
            hingeDegrees: degrees, fold: fold, rotation: .zero,
            distance: camera.distance, fieldOfViewDegrees: camera.fov, aspect: camera.aspect
        )
    }

    @Test func `should lay the unfolded screen out as two halves in the buffer's landscape-left order when flat`() throws {
        let p = pieces(180, lit: .secondary, orientation: .landscapeLeft)
        #expect(p.count == 2)
        let left = try #require(p.first), right = try #require(p.last)
        // Landscape-left: buffer x runs down the visual, buffer y runs
        // right-to-left — the buffer's top-left is the visual top-right.
        #expect(near(left.quad.topLeft, u: 0.5, v: 0.45))       // visual TR of the left half
        #expect(near(left.quad.bottomLeft, u: 0.4, v: 0.45))    // visual TL
        #expect(near(left.quad.topRight, u: 0.5, v: 0.55))      // visual BR
        #expect(left.u == 0...1 && left.v == 0.5...1)
        #expect(near(right.quad.topLeft, u: 0.6, v: 0.45))
        #expect(right.u == 0...1 && right.v == 0...0.5)
    }

    @Test func `should raise the left half toward the camera while the whole turns back when bent`() throws {
        // 90°: the left half is up by 90° less the centring turn.
        let p = pieces(90, lit: .secondary, orientation: .landscapeLeft)
        let left = try #require(p.first), right = try #require(p.last)
        // The left half's outer edge (rest x = −2) is now nearer than
        // the seam; the right half's outer edge further.
        #expect(left.quad.bottomLeft.v < left.quad.topLeft.v)   // nearer → larger on screen
        #expect(right.quad.topRight.v > right.quad.topLeft.v)
    }

    @Test func `should show the cover facing the camera on the right half in portrait order when shut`() throws {
        let p = pieces(0, lit: .primary, orientation: .portrait)
        #expect(p.count == 1)
        let c = try #require(p.first)
        // Turned 180° about the hinge: rest x → −x, so the cover's hinge
        // edge (x = 0) is its visual left and the outer edge is at x = 2.
        #expect(near(c.quad.topLeft, u: 0.5, v: 0.4500, tolerance: 0.002))
        #expect(near(c.quad.topRight, u: 0.6, v: 0.4500, tolerance: 0.002))
        #expect(near(c.quad.bottomLeft, u: 0.5, v: 0.55, tolerance: 0.002))
        #expect(c.u == 0...1 && c.v == 0...1)
    }

    @Test func `should keep a right-half button put and turn a left-half one with the book as it bends`() throws {
        let body = Vector3(x: 4, y: 2, z: 0.1)
        let marks = FoldedScreenProjection.buttons(
            [ScreenButtonAnchor(id: "power", at: Vector3(x: 2, y: 0.5, z: 0)),
             ScreenButtonAnchor(id: "camera", at: Vector3(x: -2, y: 0.5, z: 0))],
            body: body, margin: 0.5,
            hingeDegrees: 180, fold: fold, rotation: .zero,
            distance: camera.distance, fieldOfViewDegrees: camera.fov, aspect: camera.aspect
        )
        #expect(marks.map(\.id) == ["power", "camera"])
        #expect(near(marks[0].at, u: 0.6, v: 0.475))
        #expect(near(marks[1].at, u: 0.4, v: 0.475))

        let shut = FoldedScreenProjection.buttons(
            [ScreenButtonAnchor(id: "camera", at: Vector3(x: -2, y: 0.5, z: 0))],
            body: body, margin: 0.5,
            hingeDegrees: 0, fold: fold, rotation: .zero,
            distance: camera.distance, fieldOfViewDegrees: camera.fov, aspect: camera.aspect
        )
        // Turned 180° about the hinge: x → −x.
        #expect(near(shut[0].at, u: 0.6, v: 0.475))
    }

    @Test func `should place a button's control outside the body, off the edge the button is on`() throws {
        // Device Hub draws the controls beside the device, not on it:
        // a side button's control is out past that side, a top
        // button's above the top.
        let body = Vector3(x: 4, y: 2, z: 0.1)
        let marks = FoldedScreenProjection.buttons(
            [ScreenButtonAnchor(id: "power", at: Vector3(x: 2, y: 0.5, z: 0)),
             ScreenButtonAnchor(id: "volume-up", at: Vector3(x: 1, y: 1, z: 0))],
            body: body, margin: 0.5,
            hingeDegrees: 180, fold: fold, rotation: .zero,
            distance: camera.distance, fieldOfViewDegrees: camera.fov, aspect: camera.aspect
        )
        #expect(near(marks[0].control, u: 0.625, v: 0.475))   // x 2 → 2.5
        #expect(near(marks[1].control, u: 0.55, v: 0.425))    // y 1 → 1.5
    }

    @Test func `should sit the shut cover in the middle of the frame when the centring shift is applied`() throws {
        let shift = FoldPose.centring(inner: inner, hingeDegrees: 0, fold: fold)
        let p = FoldedScreenProjection.pieces(
            inner: inner, cover: cover, litPanel: .primary, orientation: .portrait,
            hingeDegrees: 0, fold: fold, rotation: .zero, offset: shift,
            distance: camera.distance, fieldOfViewDegrees: camera.fov, aspect: camera.aspect
        )
        let c = try #require(p.first)
        // Cover x 0…2 shifted by −1 → −1…1 → u 0.45…0.55.
        #expect(near(c.quad.topLeft, u: 0.45, v: 0.45, tolerance: 0.002))
        #expect(near(c.quad.topRight, u: 0.55, v: 0.45, tolerance: 0.002))
        let marks = FoldedScreenProjection.buttons(
            [ScreenButtonAnchor(id: "power", at: Vector3(x: 2, y: 0.5, z: 0))],
            body: Vector3(x: 4, y: 2, z: 0.1), margin: 0.5,
            hingeDegrees: 0, fold: fold, rotation: .zero, offset: shift,
            distance: camera.distance, fieldOfViewDegrees: camera.fov, aspect: camera.aspect
        )
        #expect(near(marks[0].at, u: 0.55, v: 0.475))
    }

    func near(_ p: NormalizedPoint, u: Double, v: Double, tolerance: Double = 1e-6) -> Bool {
        abs(p.u - u) < tolerance && abs(p.v - v) < tolerance
    }
}
