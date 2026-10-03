import Foundation
import IOSurface

/// Geometry captured in the same render operation as the composed pixels.
/// Consume the surface synchronously before the scene renders again.
struct DeviceFrame: @unchecked Sendable {
    let surface: IOSurface
    let placement: DeviceFramePlacement?
}

struct DeviceFramePlacement: Equatable, Sendable {
    let quad: ScreenQuad?
    let pieces: [ScreenPiece]?
    let buttons: [ScreenButtonMark]
    let litPanel: IntegratedPanel?
    let hingeDegrees: Double?
    let sourcePixelSize: RenderDimensions
    let textureTransform: ScreenPlacement

    var json: [String: Any] {
        var object: [String: Any] = [
            "type": "screen_quad",
            "sourcePixelSize": ["width": sourcePixelSize.width, "height": sourcePixelSize.height],
            "textureTransform": [
                "scaleX": textureTransform.scaleX, "scaleY": textureTransform.scaleY,
                "offsetX": textureTransform.offsetX, "offsetY": textureTransform.offsetY,
            ],
        ]
        if let pieces {
            object["pieces"] = pieces.map {
                [
                    "corners": Self.corners($0.quad), "u": [$0.u.lowerBound, $0.u.upperBound],
                    "v": [$0.v.lowerBound, $0.v.upperBound],
                ]
            }
            object["buttons"] = buttons.map {
                ["id": $0.id, "at": [$0.at.u, $0.at.v], "control": [$0.control.u, $0.control.v]]
            }
        } else if let quad {
            object["corners"] = Self.corners(quad)
        }
        if let litPanel { object["litPanel"] = litPanel == .primary ? "primary" : "secondary" }
        if let hingeDegrees { object["pose"] = ["hingeDegrees": hingeDegrees] }
        return object
    }

    private static func corners(_ quad: ScreenQuad) -> [[Double]] {
        [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft].map { [$0.u, $0.v] }
    }
}

/// One WebSocket message is one indivisible geometry/JPEG pair.
enum DeviceFrameEnvelope {
    static let maximumMetadataBytes = 64 * 1024
    static let maximumJPEGBytes = 16 * 1024 * 1024

    static func encode(frameID: Int, placement: DeviceFramePlacement?, jpeg: Data) throws -> Data {
        guard frameID > 0, frameID <= 9_007_199_254_740_991,
            jpeg.count >= 4, jpeg.count <= maximumJPEGBytes,
            jpeg.prefix(2) == Data([0xff, 0xd8]), jpeg.suffix(2) == Data([0xff, 0xd9])
        else {
            throw DeviceModelError.renderFailed
        }
        var object: [String: Any] = ["version": 1, "frameId": frameID, "placement": NSNull()]
        if let placement { object["placement"] = placement.json }
        let metadata = try JSONSerialization.data(withJSONObject: object)
        guard metadata.count <= maximumMetadataBytes else { throw DeviceModelError.renderFailed }
        let length = UInt32(metadata.count)
        var result = Data([
            UInt8(length >> 24), UInt8((length >> 16) & 255),
            UInt8((length >> 8) & 255), UInt8(length & 255),
        ])
        result.append(metadata)
        result.append(jpeg)
        return result
    }
}

/// A composed scene can deliver its pixels and hit geometry together.
protocol DeviceFrames: Screen {
    func startFrames(onFrame: @escaping @Sendable (Result<DeviceFrame, any Error>) -> Void) throws
}
