import Foundation

/// One JSON text frame from the companion app on the phone. Three
/// shapes exist: `hello` announces the device on either socket,
/// `attitude` rides the motion socket at sensor rate, and `format`
/// opens the video socket before the first binary frame. Malformed
/// lines throw — a silent drop would leave the twin frozen with no
/// explanation.
enum TwinEnvelope: Equatable, Sendable {
    case hello(TwinHello)
    case attitude(AttitudeSample)
    case format(VideoFormat)

    static func parse(line: String) throws -> TwinEnvelope {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            throw GestureError.invalidValue("line", expected: "a JSON object")
        }
        switch try Field.requiredString(dict, "type") {
        case "hello":    return .hello(try TwinHello.parse(dict))
        case "attitude": return .attitude(try AttitudeSample.parse(dict))
        case "format":   return .format(try VideoFormat.parse(dict))
        case let other:  throw GestureError.unknownKind(other)
        }
    }
}

/// The companion's self-introduction — the identity baguette lists a
/// physical device under.
struct TwinHello: Equatable, Sendable {
    let udid: String
    let name: String
    let model: String
    let capabilities: [String]

    static func parse(_ dict: [String: Any]) throws -> TwinHello {
        TwinHello(
            udid: try Field.requiredString(dict, "udid"),
            name: try Field.requiredString(dict, "name"),
            model: try Field.requiredString(dict, "model"),
            capabilities: (dict["capabilities"] as? [String]) ?? []
        )
    }
}

/// One gyroscope sample: the phone's attitude plus the sender's
/// monotonic timestamp (seconds), used to drop late-arriving samples.
struct AttitudeSample: Equatable, Sendable {
    let attitude: Attitude
    let timestamp: Double

    static func parse(_ dict: [String: Any]) throws -> AttitudeSample {
        guard let raw = dict["q"] as? [Any] else {
            throw GestureError.missingField("q")
        }
        let components = raw.compactMap { value -> Double? in
            if let v = value as? Double { return v }
            if let v = value as? Int    { return Double(v) }
            return nil
        }
        guard components.count == raw.count,
              let attitude = Attitude(wire: components) else {
            throw GestureError.invalidValue("q", expected: "[x, y, z, w]")
        }
        return AttitudeSample(
            attitude: attitude,
            timestamp: Field.optionalDouble(dict, "t", default: 0)
        )
    }
}

/// The video socket's opening declaration — dimensions in device
/// pixels, the capture orientation, and the codec of the binary frames
/// that follow.
struct VideoFormat: Equatable, Sendable {
    let width: Int
    let height: Int
    let orientation: DeviceOrientation
    let codec: String

    static func parse(_ dict: [String: Any]) throws -> VideoFormat {
        let orientation: DeviceOrientation
        if let name = dict["orientation"] as? String {
            guard let parsed = DeviceOrientation(wireName: name) else {
                throw GestureError.invalidValue(
                    "orientation",
                    expected: "portrait | portrait-upside-down | landscape-left | landscape-right"
                )
            }
            orientation = parsed
        } else {
            orientation = .portrait
        }
        return VideoFormat(
            width: Int(try Field.requiredDouble(dict, "width")),
            height: Int(try Field.requiredDouble(dict, "height")),
            orientation: orientation,
            codec: try Field.requiredString(dict, "codec")
        )
    }
}
