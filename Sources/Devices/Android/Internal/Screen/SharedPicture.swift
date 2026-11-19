import Foundation
import Mockable

/// The memory an emulator draws its pictures into and baguette reads them
/// from — as a simulator's framebuffer is an `IOSurface` both share. Named to
/// the emulator by `handle` (a `file://` URL), `capacity` bytes long, its
/// pixels at `pixels`. Decides nothing; the real one is `MappedSharedPicture`.
@Mockable
protocol SharedPicture: AnyObject, Sendable {
    var handle: String { get }
    var capacity: Int { get }
    var pixels: UnsafeRawPointer { get }
    /// Unmaps it and removes its file.
    func close()
}
