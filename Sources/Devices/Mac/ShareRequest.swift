import BaguetteDevice
import Foundation

/// What a viewer asks for when sharing this Mac to their device, as its page
/// sends it: `{"viewer","width","height","scale","room","use"}` — its screen
/// in its own points, how many pixels make one, how much room the Mac gets,
/// and whether the display is the main one.
struct ShareRequest: Equatable, Sendable {
    struct Invalid: Error, Equatable {
        let reason: String
    }

    let viewer: String
    let shape: SharedScreenShape
    let use: ShareUse

    /// The largest screen side and pixel density a viewer may report.
    static let largestSide = 20_000.0
    static let largestScale = 10.0

    static func parse(_ body: String) throws -> ShareRequest {
        guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else {
            throw Invalid(reason: "the body must be a JSON object")
        }
        guard let width = object["width"] as? Double, let height = object["height"] as? Double,
              width > 0, height > 0 else {
            throw Invalid(reason: "width and height, the viewer's screen in its points, are required")
        }
        // No device's screen is larger: beyond it a shape overflows.
        guard width <= Self.largestSide, height <= Self.largestSide else {
            throw Invalid(reason: "width and height are at most \(Int(Self.largestSide)) points")
        }
        let scale = object["scale"] as? Double ?? 2
        guard scale > 0, scale <= Self.largestScale else {
            throw Invalid(reason: "scale is the viewer's pixels per point, above 0 and at most \(Int(Self.largestScale))")
        }
        guard let room = SharedScreenShape.Room(wire: object["room"] as? String) else {
            throw Invalid(reason: "room is largerText, standard or moreSpace")
        }
        guard let use = ShareUse(wire: object["use"] as? String) else {
            throw Invalid(reason: "use is main or extra")
        }
        let viewer = ViewerScreen(points: Size(width: width, height: height),
                                  pixelsPerPoint: scale)
        let name = (object["viewer"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(40)) } ?? "viewer"
        return ShareRequest(viewer: name, shape: SharedScreenShape(viewer: viewer, room: room), use: use)
    }
}
