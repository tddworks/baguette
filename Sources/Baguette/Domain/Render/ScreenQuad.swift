import Foundation

/// A point in the device model's local coordinate space — plain Foundation
/// math, no `simd`, so Domain stays free of the RealityKit/simd dependency
/// that Infrastructure carries.
struct Vector3: Equatable, Sendable {
    let x: Double
    let y: Double
    let z: Double
}

/// The four corners of the device's screen mesh in local (unrotated)
/// device space, as authored in the loaded 3D model.
struct ScreenLocalCorners: Equatable, Sendable {
    let topLeft: Vector3
    let topRight: Vector3
    let bottomRight: Vector3
    let bottomLeft: Vector3

    /// Derives the screen's four corners from its axis-aligned bounding box.
    /// The thinnest extent is the screen's face normal — the same
    /// axis-picking rule `RealityKitDeviceScene.addCoverGlass` uses to lift
    /// the cover-glass layer along the display normal. Of the remaining two
    /// axes, Y is treated as vertical (screen up/down) unless Y itself is
    /// the thin axis, matching every device model authored so far (phones
    /// and tablets stand upright with the screen facing along X or Z).
    static func from(center: Vector3, extents: Vector3) -> ScreenLocalCorners {
        let verticalAxis: Axis
        let horizontalAxis: Axis
        if extents.y <= extents.x, extents.y <= extents.z {
            verticalAxis = extents.z <= extents.x ? .z : .x
            horizontalAxis = verticalAxis == .z ? .x : .z
        } else {
            verticalAxis = .y
            horizontalAxis = extents.x <= extents.z ? .z : .x
        }

        let halfHeight = verticalAxis.component(of: extents) / 2
        let halfWidth = horizontalAxis.component(of: extents) / 2

        func corner(left: Bool, top: Bool) -> Vector3 {
            var point = center
            point = horizontalAxis.offsetting(point, by: left ? -halfWidth : halfWidth)
            point = verticalAxis.offsetting(point, by: top ? halfHeight : -halfHeight)
            return point
        }

        return ScreenLocalCorners(
            topLeft: corner(left: true, top: true),
            topRight: corner(left: false, top: true),
            bottomRight: corner(left: false, top: false),
            bottomLeft: corner(left: true, top: false)
        )
    }

    private enum Axis {
        case x, y, z

        func component(of vector: Vector3) -> Double {
            switch self {
            case .x: return vector.x
            case .y: return vector.y
            case .z: return vector.z
            }
        }

        func offsetting(_ vector: Vector3, by delta: Double) -> Vector3 {
            switch self {
            case .x: return Vector3(x: vector.x + delta, y: vector.y, z: vector.z)
            case .y: return Vector3(x: vector.x, y: vector.y + delta, z: vector.z)
            case .z: return Vector3(x: vector.x, y: vector.y, z: vector.z + delta)
            }
        }
    }
}

/// A point in normalized image space: (0,0) is the top-left of the
/// rendered frame, (1,1) the bottom-right.
struct NormalizedPoint: Equatable, Sendable {
    let u: Double
    let v: Double
}

/// Where the device's screen mesh lands in the rendered image for the
/// current camera pose — the four corners `ScreenQuadProjection.project`
/// computes.
struct ScreenQuad: Equatable, Sendable {
    let topLeft: NormalizedPoint
    let topRight: NormalizedPoint
    let bottomRight: NormalizedPoint
    let bottomLeft: NormalizedPoint
}

/// Projects the screen's local-space corners through the exact device
/// rotation and perspective camera `RealityKitDeviceScene` renders with, so
/// the browser can map a click on the rendered image back to a point on the
/// screen mesh without ray-casting into the GPU scene itself.
///
/// Mirrors two things the renderer does, expressed as pure trig:
/// - `RealityKitDeviceScene.orientation(_:)` composes `qz * qy * qx`, which
///   rotates a vector by the world X axis, then Y, then Z (in that order).
/// - The camera sits on the world Z axis at `(0, 0, distance)` with no
///   rotation, looking at the origin down -Z, using a fixed *vertical* FOV
///   (`DeviceCameraFraming.fieldOfViewDegrees`) with the horizontal FOV
///   derived from the output aspect ratio — the same convention
///   `RealityRenderer`/`PerspectiveCamera` uses.
enum ScreenQuadProjection {
    static func project(
        corners: ScreenLocalCorners,
        rotation: DeviceRotation,
        distance: Double,
        fieldOfViewDegrees: Double,
        aspect: Double
    ) -> ScreenQuad {
        ScreenQuad(
            topLeft: project(corners.topLeft, rotation: rotation, distance: distance, fieldOfViewDegrees: fieldOfViewDegrees, aspect: aspect),
            topRight: project(corners.topRight, rotation: rotation, distance: distance, fieldOfViewDegrees: fieldOfViewDegrees, aspect: aspect),
            bottomRight: project(corners.bottomRight, rotation: rotation, distance: distance, fieldOfViewDegrees: fieldOfViewDegrees, aspect: aspect),
            bottomLeft: project(corners.bottomLeft, rotation: rotation, distance: distance, fieldOfViewDegrees: fieldOfViewDegrees, aspect: aspect)
        )
    }

    /// Quaternion twin of the euler projection — the gyro path. The
    /// rotation is applied through `Attitude.rotate`, so this and the
    /// entity the renderer poses share one transform by construction.
    static func project(
        corners: ScreenLocalCorners,
        attitude: Attitude,
        distance: Double,
        fieldOfViewDegrees: Double,
        aspect: Double
    ) -> ScreenQuad {
        func one(_ point: Vector3) -> NormalizedPoint {
            projectRotated(
                attitude.rotate(point),
                distance: distance,
                fieldOfViewDegrees: fieldOfViewDegrees,
                aspect: aspect
            )
        }
        return ScreenQuad(
            topLeft: one(corners.topLeft),
            topRight: one(corners.topRight),
            bottomRight: one(corners.bottomRight),
            bottomLeft: one(corners.bottomLeft)
        )
    }

    private static func projectRotated(
        _ rotated: Vector3,
        distance: Double,
        fieldOfViewDegrees: Double,
        aspect: Double
    ) -> NormalizedPoint {
        let depth = distance - rotated.z
        let halfVertical = fieldOfViewDegrees * .pi / 360
        let halfHorizontal = atan(tan(halfVertical) * aspect)
        let ndcX = rotated.x / (depth * tan(halfHorizontal))
        let ndcY = rotated.y / (depth * tan(halfVertical))
        return NormalizedPoint(u: (ndcX + 1) / 2, v: (1 - ndcY) / 2)
    }

    private static func project(
        _ point: Vector3,
        rotation: DeviceRotation,
        distance: Double,
        fieldOfViewDegrees: Double,
        aspect: Double
    ) -> NormalizedPoint {
        let rotated = rotate(point, by: rotation)
        let depth = distance - rotated.z
        let halfVertical = fieldOfViewDegrees * .pi / 360
        let halfHorizontal = atan(tan(halfVertical) * aspect)
        let ndcX = rotated.x / (depth * tan(halfHorizontal))
        let ndcY = rotated.y / (depth * tan(halfVertical))
        return NormalizedPoint(u: (ndcX + 1) / 2, v: (1 - ndcY) / 2)
    }

    /// Applies world-X, then world-Y, then world-Z rotation — the same
    /// order `RealityKitDeviceScene.orientation(_:)`'s `qz * qy * qx`
    /// quaternion composition applies to a vector.
    private static func rotate(_ v: Vector3, by rotation: DeviceRotation) -> Vector3 {
        var point = v
        point = rotateX(point, degrees: rotation.x)
        point = rotateY(point, degrees: rotation.y)
        point = rotateZ(point, degrees: rotation.z)
        return point
    }

    private static func rotateX(_ v: Vector3, degrees: Double) -> Vector3 {
        let radians = degrees * .pi / 180
        let cosA = cos(radians)
        let sinA = sin(radians)
        return Vector3(
            x: v.x,
            y: v.y * cosA - v.z * sinA,
            z: v.y * sinA + v.z * cosA
        )
    }

    private static func rotateY(_ v: Vector3, degrees: Double) -> Vector3 {
        let radians = degrees * .pi / 180
        let cosA = cos(radians)
        let sinA = sin(radians)
        return Vector3(
            x: v.x * cosA + v.z * sinA,
            y: v.y,
            z: -v.x * sinA + v.z * cosA
        )
    }

    private static func rotateZ(_ v: Vector3, degrees: Double) -> Vector3 {
        let radians = degrees * .pi / 180
        let cosA = cos(radians)
        let sinA = sin(radians)
        return Vector3(
            x: v.x * cosA - v.y * sinA,
            y: v.x * sinA + v.y * cosA,
            z: v.z
        )
    }
}
