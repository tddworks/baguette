import BaguetteDevice
import Foundation

struct Device3DCamera: Equatable, Sendable {
    let rotation: DeviceRotation
    let zoom: Double
    /// The guest's interface orientation, when the page turned a
    /// foldable and knows it: the lit screen's pieces are then ordered
    /// as that framebuffer is drawn. nil leaves the scene's assumption.
    let orientation: DeviceOrientation?

    init(rotation: DeviceRotation, zoom: Double, orientation: DeviceOrientation? = nil) {
        self.rotation = rotation
        self.zoom = zoom
        self.orientation = orientation
    }

    static func parsing(json: Data) throws -> Device3DCamera? {
        let object: [String: Any]
        do {
            object = try JSONSerialization.jsonObject(with: json) as? [String: Any] ?? [:]
        } catch {
            throw DeviceModelError.invalidRenderOptions
        }
        guard object["type"] as? String == "set_3d_camera" else { return nil }
        guard let rotation = object["rotation"] as? [String: Any],
              let x = number(rotation["x"]),
              let y = number(rotation["y"]),
              let z = number(rotation["z"]),
              let zoom = number(object["zoom"]),
              (-80...80).contains(x),
              (-180...180).contains(y),
              (-180...180).contains(z),
              (0.5...3).contains(zoom) else {
            throw DeviceModelError.invalidRenderOptions
        }
        var orientation: DeviceOrientation?
        if let name = object["orientation"] {
            guard let text = name as? String, let parsed = DeviceOrientation(wireName: text) else {
                throw DeviceModelError.invalidRenderOptions
            }
            orientation = parsed
        }
        return Device3DCamera(
            rotation: DeviceRotation(x: x, y: y, z: z),
            zoom: zoom,
            orientation: orientation
        )
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }
}
