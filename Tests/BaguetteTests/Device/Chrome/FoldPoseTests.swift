import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDevice

// The hinge angle poses the book. The shutting clip runs from flat (its
// start) to shut (the definition's shut time); it raises the left half
// alone, so the whole device turns back by half the fold to centre the
// bend — fully above the open pose, as Device Hub draws it, handing over
// to the cover-forward pose as the book shuts.
@Suite("FoldPose")
struct FoldPoseTests {
    let fold = DeviceModelFold(
        clip: "l_over_r", shutTime: 5.0,
        coverMaterial: "cover", coverTextureSize: RenderDimensions(width: 1, height: 1),
        openPoseDegrees: 130
    )

    @Test func `should start the clip with no turn when flat`() {
        let pose = FoldPose.at(degrees: 180, fold: fold)
        #expect(pose.clipTime == 0)
        #expect(pose.yawDegrees == 0)
    }

    @Test func `should reach the clip's shut time with the cover facing the camera when shut`() {
        let pose = FoldPose.at(degrees: 0, fold: fold)
        #expect(pose.clipTime == 5.0)
        #expect(pose.yawDegrees == 0)
    }

    @Test func `should centre the open pose with half the fold turned back`() {
        let pose = FoldPose.at(degrees: 130, fold: fold)
        #expect(abs(pose.clipTime - 50.0 / 180 * 5) < 1e-9)
        #expect(pose.yawDegrees == -25)
    }

    @Test func `should hand the turn over in proportion between open and shut`() {
        let pose = FoldPose.at(degrees: 65, fold: fold)
        // fold 115°, half 57.5°, share 0.5
        #expect(abs(pose.yawDegrees - (-28.75)) < 1e-9)
    }

    @Test func `should clamp angles outside the hinge's range`() {
        #expect(FoldPose.at(degrees: 200, fold: fold).clipTime == 0)
        #expect(FoldPose.at(degrees: -5, fold: fold).clipTime == 5.0)
    }
}

// The book stands the way the guest is held. The lit panel has an
// orientation of its own — the unfolded panel is landscape-left lying
// flat in the model, the cover portrait — and each step of the
// interface cycle turns the device another quarter turn.
@Suite("InterfaceRoll")
struct InterfaceRollTests {
    @Test func `should leave the model as it stands in the lit panel's own orientation`() {
        #expect(InterfaceRoll.degrees(.landscapeLeft, litPanel: .secondary) == 0)
        #expect(InterfaceRoll.degrees(.portrait, litPanel: .primary) == 0)
    }

    @Test func `should stand the book up for a portrait interface on the unfolded panel`() {
        // Measured against Device Hub: the guest reporting "Portrait
        // Upside Down" on the unfolded panel stands the book with its
        // left half up, i.e. a quarter turn the other way round.
        #expect(InterfaceRoll.degrees(.portrait, litPanel: .secondary) == 90)
        #expect(InterfaceRoll.degrees(.portraitUpsideDown, litPanel: .secondary) == -90)
        #expect(InterfaceRoll.degrees(.landscapeRight, litPanel: .secondary) == 180)
    }

    @Test func `should turn the shut cover a quarter turn for landscape interfaces`() {
        #expect(InterfaceRoll.degrees(.landscapeLeft, litPanel: .primary) == -90)
        #expect(InterfaceRoll.degrees(.landscapeRight, litPanel: .primary) == 90)
    }
}

// As the book shuts, its left half lands on the right and the shut book
// sits to one side of where the flat one was. Device Hub keeps the
// device in the middle of its window through the whole fold, so the
// pose carries the shift that recentres it: the bent screen's extent
// after the clip's raise and the centring turn, brought back to zero.
@Suite("FoldPose centring")
struct FoldPoseCentringTests {
    let fold = DeviceModelFold(
        clip: "l_over_r", shutTime: 5.0,
        coverMaterial: "cover", coverTextureSize: RenderDimensions(width: 1, height: 1),
        openPoseDegrees: 130
    )
    let inner = ScreenLocalCorners(
        topLeft: Vector3(x: -2, y: 1, z: 0), topRight: Vector3(x: 2, y: 1, z: 0),
        bottomRight: Vector3(x: 2, y: -1, z: 0), bottomLeft: Vector3(x: -2, y: -1, z: 0)
    )

    @Test func `should leave the book where it lies when flat and at the open pose`() {
        #expect(FoldPose.centring(inner: inner, hingeDegrees: 180, fold: fold).x == 0)
        let open = FoldPose.centring(inner: inner, hingeDegrees: 130, fold: fold)
        #expect(abs(open.x) < 1e-9)
    }

    @Test func `should bring the book back to the middle when shut onto its right half`() {
        // The left half turned 180° lies over the right (x 0…2): the
        // book's extent is 0…2, its middle 1, the shift −1.
        let shut = FoldPose.centring(inner: inner, hingeDegrees: 0, fold: fold)
        #expect(abs(shut.x - (-1)) < 1e-9)
        #expect(shut.y == 0)
    }

    @Test func `should shift the book by its bent extent when half way`() {
        // 90°: left half up by 90° less the turn (share 90/130 of 45°).
        let mid = FoldPose.centring(inner: inner, hingeDegrees: 90, fold: fold)
        #expect(mid.x < 0 && mid.x > -1)
    }
}
