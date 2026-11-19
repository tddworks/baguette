import Foundation
import IOSurface

/// The latest frame of each of a foldable's panels, as handed to the
/// scene: the unfolded panel on the book's inside, the cover on the far
/// side of the leaf that folds over. Either may still be missing — a
/// dark panel emits nothing — and its screen then stays as it was.
public struct FoldableScreens: Equatable, Sendable {
    public let unfolded: IOSurface?
    public let cover: IOSurface?

    public static func == (lhs: FoldableScreens, rhs: FoldableScreens) -> Bool {
        lhs.unfolded === rhs.unfolded && lhs.cover === rhs.cover
    }

    public init(unfolded: IOSurface?, cover: IOSurface?) {
        self.unfolded = unfolded
        self.cover = cover
    }
}
