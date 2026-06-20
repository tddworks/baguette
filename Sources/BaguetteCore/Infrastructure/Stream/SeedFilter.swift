import Foundation
import IOSurface

/// "Did the pixels actually change since I last asked?" — a one-property
/// value that compares `IOSurfaceGetSeed` against the previous answer.
/// Composed into each `Stream` so an idle simulator stops the wire.
struct SeedFilter {
    private var last: UInt32 = 0

    mutating func shouldEmit(_ surface: IOSurface) -> Bool {
        var seed: UInt32 = 0
        surface.lock(options: .readOnly, seed: &seed)
        surface.unlock(options: .readOnly, seed: nil)
        guard seed != last else { return false }
        last = seed
        return true
    }
}
