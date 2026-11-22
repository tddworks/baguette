import BaguetteDevice
import CryptoKit
import Foundation

/// The Mac's pointer as it is read, many times a second: its shape said once
/// per change — known by an id that follows from its image, so a shape the
/// pointer comes back to keeps its id and a page fetches it once.
struct PointerShapeChanges {
    private var last: String?

    /// The shape read now, when it isn't the one read last; nil when it is.
    /// `image`: what identifies it (its full image data); `png`: what a page draws.
    mutating func read(image: Data, png: Data, hotspot: Point, size: Size) -> PointerShape? {
        let id = SHA256.hash(data: image).prefix(4).map { String(format: "%02x", $0) }.joined()
        guard id != last else { return nil }
        last = id
        return PointerShape(id: id, hotspot: hotspot, size: size, png: png)
    }
}
