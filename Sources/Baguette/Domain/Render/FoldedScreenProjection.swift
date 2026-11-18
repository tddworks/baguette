import BaguetteDevice
import Foundation

/// One flat piece of a foldable's lit screen in the rendered image: its
/// projected quad, with corners in the framebuffer's own order, and the
/// part of the framebuffer it shows (normalized ranges).
struct ScreenPiece: Equatable, Sendable {
    let quad: ScreenQuad
    let u: ClosedRange<Double>
    let v: ClosedRange<Double>
}

/// A hardware button's place on the model, in the rest frame.
struct ScreenButtonAnchor: Equatable, Sendable {
    let id: String
    let at: Vector3
}

/// Where a hardware button lands in the rendered image, and where its
/// control goes: beside the device, off the edge the button is on.
struct ScreenButtonMark: Equatable, Sendable {
    let id: String
    let at: NormalizedPoint
    let control: NormalizedPoint
}

/// Where a foldable's lit screen lands in the rendered image, for the
/// pose `FoldPose` gives a hinge angle.
///
/// Both screens are given in the model's rest frame — flat, facing the
/// camera at +z, the hinge the y axis through x = 0, the left half at
/// x < 0 and the cover on its back. The model's shutting clip raises the
/// left half about the hinge toward the camera; the centring turn then
/// applies to everything, and the requested rotation after that, before
/// the same perspective `ScreenQuadProjection` uses.
///
/// The unfolded screen bends at the hinge, so it is two pieces. Its
/// buffer lies landscape-left on the mesh — a portrait buffer whose
/// rows run along the long axis, whatever the guest draws into it —
/// so each piece's corners are named in the buffer's order and it
/// carries the buffer range it shows; the browser maps a click
/// straight to buffer space, where touches land.
enum FoldedScreenProjection {
    static func pieces(
        inner: ScreenLocalCorners,
        cover: ScreenLocalCorners,
        litPanel: IntegratedPanel,
        orientation: DeviceOrientation,
        hingeDegrees: Double,
        fold: DeviceModelFold,
        rotation: DeviceRotation,
        offset: Vector3 = Vector3(x: 0, y: 0, z: 0),
        distance: Double,
        fieldOfViewDegrees: Double,
        aspect: Double
    ) -> [ScreenPiece] {
        let pose = FoldPose.at(degrees: hingeDegrees, fold: fold)
        let raise = 180 - max(0, min(180, hingeDegrees))
        let leftHalf = { (p: Vector3) -> Vector3 in
            ScreenQuadProjection.rotateY(p, degrees: raise)
        }
        let project = { (p: Vector3) -> NormalizedPoint in
            let turned = ScreenQuadProjection.rotateY(p, degrees: pose.yawDegrees)
            let placed = Vector3(x: turned.x + offset.x, y: turned.y + offset.y, z: turned.z + offset.z)
            return ScreenQuadProjection.projectRotated(
                ScreenQuadProjection.rotate(placed, by: rotation),
                distance: distance, fieldOfViewDegrees: fieldOfViewDegrees, aspect: aspect
            )
        }

        switch litPanel {
        case .primary:
            // Shut, the cover has turned with the left half to face the
            // camera, mirrored: its hinge edge is now its visual left.
            let visual = VisualCorners(
                topLeft: leftHalf(cover.topRight), topRight: leftHalf(cover.topLeft),
                bottomRight: leftHalf(cover.bottomLeft), bottomLeft: leftHalf(cover.bottomRight)
            )
            return [ScreenPiece(
                quad: visual.projected(project).inBufferOrder(orientation),
                u: 0...1, v: 0...1
            )]
        case .secondary:
            let seamTop = Vector3(x: 0, y: inner.topLeft.y, z: inner.topLeft.z)
            let seamBottom = Vector3(x: 0, y: inner.bottomLeft.y, z: inner.bottomLeft.z)
            let left = VisualCorners(
                topLeft: leftHalf(inner.topLeft), topRight: seamTop,
                bottomRight: seamBottom, bottomLeft: leftHalf(inner.bottomLeft)
            )
            let right = VisualCorners(
                topLeft: seamTop, topRight: inner.topRight,
                bottomRight: inner.bottomRight, bottomLeft: seamBottom
            )
            let leftRange = bufferRange(visualX: 0...0.5, orientation: orientation)
            let rightRange = bufferRange(visualX: 0.5...1, orientation: orientation)
            return [
                ScreenPiece(quad: left.projected(project).inBufferOrder(orientation),
                            u: leftRange.u, v: leftRange.v),
                ScreenPiece(quad: right.projected(project).inBufferOrder(orientation),
                            u: rightRange.u, v: rightRange.v),
            ]
        }
    }

    /// Where the model's buttons land: those on the left half (x < 0)
    /// turn with it as the book shuts, the rest only with the whole.
    /// `body` is the flat device's extents in the rest frame; a
    /// button's control is pushed `margin` out past whichever edge —
    /// side or top/bottom — the button sits on, as Device Hub draws
    /// them beside the device.
    static func buttons(
        _ anchors: [ScreenButtonAnchor],
        body: Vector3,
        margin: Double,
        hingeDegrees: Double,
        fold: DeviceModelFold,
        rotation: DeviceRotation,
        offset: Vector3 = Vector3(x: 0, y: 0, z: 0),
        distance: Double,
        fieldOfViewDegrees: Double,
        aspect: Double
    ) -> [ScreenButtonMark] {
        let pose = FoldPose.at(degrees: hingeDegrees, fold: fold)
        let raise = 180 - max(0, min(180, hingeDegrees))
        let project = { (anchor: Vector3, point: Vector3) -> NormalizedPoint in
            var p = point
            if anchor.x < 0 { p = ScreenQuadProjection.rotateY(p, degrees: raise) }
            p = ScreenQuadProjection.rotateY(p, degrees: pose.yawDegrees)
            p = Vector3(x: p.x + offset.x, y: p.y + offset.y, z: p.z + offset.z)
            return ScreenQuadProjection.projectRotated(
                ScreenQuadProjection.rotate(p, by: rotation),
                distance: distance, fieldOfViewDegrees: fieldOfViewDegrees, aspect: aspect
            )
        }
        return anchors.map { anchor in
            let p = anchor.at
            let onSide = abs(p.x) / max(body.x / 2, 1e-9) >= abs(p.y) / max(body.y / 2, 1e-9)
            let outward = onSide
                ? Vector3(x: p.x < 0 ? -margin : margin, y: 0, z: 0)
                : Vector3(x: 0, y: p.y < 0 ? -margin : margin, z: 0)
            let control = Vector3(x: p.x + outward.x, y: p.y + outward.y, z: p.z)
            return ScreenButtonMark(id: anchor.id, at: project(p, p), control: project(p, control))
        }
    }

    /// The part of the framebuffer a visual x-range of the screen shows,
    /// as `visualToPortraitNorm` in the page maps points.
    private static func bufferRange(
        visualX: ClosedRange<Double>, orientation: DeviceOrientation
    ) -> (u: ClosedRange<Double>, v: ClosedRange<Double>) {
        switch orientation {
        case .landscapeLeft:       // x' = y, y' = 1 − x
            return (0...1, (1 - visualX.upperBound)...(1 - visualX.lowerBound))
        case .landscapeRight:      // x' = 1 − y, y' = x
            return (0...1, visualX)
        case .portraitUpsideDown:  // x' = 1 − x
            return ((1 - visualX.upperBound)...(1 - visualX.lowerBound), 0...1)
        case .portrait:
            return (visualX, 0...1)
        }
    }

    private struct VisualCorners {
        let topLeft: Vector3, topRight: Vector3, bottomRight: Vector3, bottomLeft: Vector3

        func projected(_ project: (Vector3) -> NormalizedPoint) -> ScreenQuad {
            ScreenQuad(
                topLeft: project(topLeft), topRight: project(topRight),
                bottomRight: project(bottomRight), bottomLeft: project(bottomLeft)
            )
        }
    }
}

private extension ScreenQuad {
    /// The same quad with its corners named as the framebuffer sees
    /// them: the buffer's top-left is the corner the guest's rotation
    /// put there (`visualToPortraitNorm`'s inverse at the corners).
    func inBufferOrder(_ orientation: DeviceOrientation) -> ScreenQuad {
        switch orientation {
        case .portrait:
            return self
        case .landscapeLeft:
            return ScreenQuad(topLeft: topRight, topRight: bottomRight,
                              bottomRight: bottomLeft, bottomLeft: topLeft)
        case .landscapeRight:
            return ScreenQuad(topLeft: bottomLeft, topRight: topLeft,
                              bottomRight: topRight, bottomLeft: bottomRight)
        case .portraitUpsideDown:
            return ScreenQuad(topLeft: bottomRight, topRight: bottomLeft,
                              bottomRight: topLeft, bottomLeft: topRight)
        }
    }
}
