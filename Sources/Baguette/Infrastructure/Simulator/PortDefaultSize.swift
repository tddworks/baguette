import BaguetteDevice
import Foundation
import ObjectiveC

/// Reads a framebuffer IO-port's fallback size from KVC accessors the
/// port actually exposes. ROCK remote proxies throw `NSUnknownKeyException`
/// on undefined keys — never call `value(forKey:)` without `responds(to:)`.
enum PortDefaultSize {
    static func read(from port: NSObject) -> Size? {
        let w = number(from: port, keys: ["defaultWidth", "width"])
        let h = number(from: port, keys: ["defaultHeight", "height"])
        guard let w, let h, w > 0, h > 0 else { return nil }
        return Size(width: w, height: h)
    }

    private static func number(from object: NSObject, keys: [String]) -> Double? {
        for key in keys {
            guard object.responds(to: NSSelectorFromString(key)) else { continue }
            if let n = object.value(forKey: key) as? NSNumber {
                return n.doubleValue
            }
        }
        return nil
    }
}
