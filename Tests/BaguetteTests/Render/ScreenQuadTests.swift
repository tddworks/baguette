import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDevice

@Suite("ScreenLocalCorners")
struct ScreenLocalCornersTests {
    @Test func `should derive screen corners from a box whose thinnest axis is depth`() {
        let corners = ScreenLocalCorners.from(
            center: Vector3(x: 0, y: 1, z: 0.5),
            extents: Vector3(x: 2, y: 4, z: 0.1)
        )

        #expect(corners.topLeft == Vector3(x: -1, y: 3, z: 0.5))
        #expect(corners.topRight == Vector3(x: 1, y: 3, z: 0.5))
        #expect(corners.bottomRight == Vector3(x: 1, y: -1, z: 0.5))
        #expect(corners.bottomLeft == Vector3(x: -1, y: -1, z: 0.5))
    }
}

@Suite("ScreenQuadProjection")
struct ScreenQuadProjectionTests {
    static let symmetricCorners = ScreenLocalCorners(
        topLeft: Vector3(x: -1, y: 2, z: 0),
        topRight: Vector3(x: 1, y: 2, z: 0),
        bottomRight: Vector3(x: 1, y: -2, z: 0),
        bottomLeft: Vector3(x: -1, y: -2, z: 0)
    )

    @Test func `should project a front-on symmetric screen into a horizontally and vertically centered quad`() {
        let quad = ScreenQuadProjection.project(
            corners: Self.symmetricCorners,
            rotation: .zero,
            distance: 10,
            fieldOfViewDegrees: 32,
            aspect: 1
        )

        #expect(abs((quad.topLeft.u + quad.topRight.u) - 1) < 0.000_001)
        #expect(abs((quad.topLeft.v + quad.bottomLeft.v) - 1) < 0.000_001)
        #expect(quad.topLeft.u < quad.topRight.u)
        #expect(quad.topLeft.v < quad.bottomLeft.v)
    }

    @Test func `should see a screen turned 90 degrees in yaw edge-on with every corner centered horizontally`() {
        let quad = ScreenQuadProjection.project(
            corners: Self.symmetricCorners,
            rotation: DeviceRotation(x: 0, y: 90, z: 0),
            distance: 10,
            fieldOfViewDegrees: 32,
            aspect: 1
        )

        for u in [quad.topLeft.u, quad.topRight.u, quad.bottomRight.u, quad.bottomLeft.u] {
            #expect(abs(u - 0.5) < 0.000_001)
        }
    }

    @Test func `should see a screen pitched 90 degrees edge-on with every corner centered vertically`() {
        let quad = ScreenQuadProjection.project(
            corners: Self.symmetricCorners,
            rotation: DeviceRotation(x: 90, y: 0, z: 0),
            distance: 10,
            fieldOfViewDegrees: 32,
            aspect: 1
        )

        for v in [quad.topLeft.v, quad.topRight.v, quad.bottomRight.v, quad.bottomLeft.v] {
            #expect(abs(v - 0.5) < 0.000_001)
        }
    }

    @Test func `should shrink the quad toward the center as the camera moves farther away`() {
        let near = ScreenQuadProjection.project(
            corners: Self.symmetricCorners,
            rotation: .zero,
            distance: 10,
            fieldOfViewDegrees: 32,
            aspect: 1
        )
        let far = ScreenQuadProjection.project(
            corners: Self.symmetricCorners,
            rotation: .zero,
            distance: 20,
            fieldOfViewDegrees: 32,
            aspect: 1
        )

        #expect(far.topRight.u < near.topRight.u)
        #expect(far.topLeft.v > near.topLeft.v)
    }
}
