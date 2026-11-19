import BaguetteDevice
import Foundation

/// An Android device's screen in pixels, as `adb shell wm size` says —
/// `Physical size: 1080x2400`, and an `Override size:` a developer set
/// takes over it. Touches are sent in these pixels; a scroll's distance in
/// points becomes pixels at the screen's density.
enum AndroidScreenSize {
    static func pixels(fromWmSize output: String) -> Size? {
        let sizes = output.split(whereSeparator: \.isNewline).reduce(into: [String: Size]()) { sizes, line in
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let numbers = parts.count == 2 ? parts[1].split(separator: "x").compactMap { Double($0) } : []
            if numbers.count == 2 { sizes[parts[0]] = Size(width: numbers[0], height: numbers[1]) }
        }
        return sizes["Override size"] ?? sizes["Physical size"]
    }

    /// Pixels per point (Android's dp), from `adb shell wm density`: the
    /// density over 160, an `Override density:` taking over the physical one.
    static func pixelsPerPoint(fromWmDensity output: String) -> Double? {
        let densities = output.split(whereSeparator: \.isNewline).reduce(into: [String: Double]()) { found, line in
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, let value = Double(parts[1]) { found[parts[0]] = value }
        }
        return (densities["Override density"] ?? densities["Physical density"]).map { $0 / 160 }
    }
}
