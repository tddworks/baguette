import Foundation

/// Display preferences shipped with every frame written into the
/// shared-memory ring buffer. Bit layout matches `VirtualCamera`'s
/// `SharedFrameReader.h` (bit 0 = fillGravity, bit 1 = mirror) — the
/// reader OR-masks them and applies on the next display-link tick.
public struct CameraFlags: Equatable, Sendable {
    public var fillGravity: Bool
    public var mirror: Bool

    public init(fillGravity: Bool = false, mirror: Bool = false) {
        self.fillGravity = fillGravity
        self.mirror = mirror
    }

    public func packed() -> UInt32 {
        var bits: UInt32 = 0
        if fillGravity { bits |= 1 << 0 }
        if mirror      { bits |= 1 << 1 }
        return bits
    }
}
