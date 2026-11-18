import BaguetteDevice
import Foundation

enum DeviceRenderArguments {
    static func rotation(_ value: String) throws -> DeviceRotation {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let x = Double(parts[0]),
              let y = Double(parts[1]),
              let z = Double(parts[2]),
              x.isFinite, y.isFinite, z.isFinite else {
            throw DeviceModelError.invalidRotationArgument(value)
        }
        return DeviceRotation(x: x, y: y, z: z)
    }

    /// `--size` in the shared capture vocabulary: a preset name
    /// (`appstore-6.9`, `square`), literal `WIDTHxHEIGHT`, or a bare ratio
    /// (`3:2`). A ratio means nothing on its own — the caller resolves the
    /// returned value against the captured screen, the same source the
    /// default (`native`) renders at.
    ///
    /// `CaptureSize.parse` speaks `CaptureSizeError`, but this is the CLI's
    /// `--size` argument, so it keeps reporting the argument error
    /// `render-3d` has always reported for a size it can't read. Nothing is
    /// substituted for an unreadable size — same bar as an unknown model.
    static func captureSize(_ value: String) throws -> CaptureSize {
        do {
            return try CaptureSize.parse(value)
        } catch {
            throw DeviceModelError.invalidSizeArgument(value)
        }
    }

    static func variants(_ values: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for value in values {
            let parts = value.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                throw DeviceModelError.invalidVariantArgument(value)
            }
            let set = String(parts[0])
            guard result[set] == nil else {
                throw DeviceModelError.duplicateVariantSelection(set)
            }
            result[set] = String(parts[1])
        }
        return result
    }
}
