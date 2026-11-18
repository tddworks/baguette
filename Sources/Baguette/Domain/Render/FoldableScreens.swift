import BaguetteDevice
import Foundation
import IOSurface

/// The latest frame of each of a foldable's panels, as handed to the
/// scene: the unfolded panel on the book's inside, the cover on the far
/// side of the leaf that folds over. Either may still be missing — a
/// dark panel emits nothing — and its screen then stays as it was.
struct FoldableScreens: Equatable, Sendable {
    let unfolded: IOSurface?
    let cover: IOSurface?

    static func == (lhs: FoldableScreens, rhs: FoldableScreens) -> Bool {
        lhs.unfolded === rhs.unfolded && lhs.cover === rhs.cover
    }
}
