import Foundation
import Mockable

/// One viewer's watch of the pointer; `end()` stops it hearing.
public struct PointerWatch: Sendable {
    public let end: @Sendable () -> Void
}

/// The Mac's pointer shape, for whoever is viewing a Mac display: each change
/// heard — the shape now at once — and each shape's image by id, for a page
/// to fetch once. The real one is `ChildPointerShapes`.
@Mockable
public protocol PointerShapes: Sendable {
    func watch(_ hear: @escaping @Sendable (PointerShape) -> Void) -> PointerWatch
    func image(id: String) -> Data?
}
