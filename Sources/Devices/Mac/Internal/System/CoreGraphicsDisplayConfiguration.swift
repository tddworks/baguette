import BaguetteDevice
import CoreGraphics
import Foundation

/// The session's display configuration through CoreGraphics. Integration-only:
/// when and where to place displays is `MainDisplayMove`'s.
struct CoreGraphicsDisplayConfiguration: DisplayConfiguration {
    var main: UInt32 { CGMainDisplayID() }

    func bounds() -> [UInt32: Rect]? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        return Dictionary(uniqueKeysWithValues: ids.prefix(Int(count)).map { id in
            (id, Rect(origin: Point(x: CGDisplayBounds(id).origin.x, y: CGDisplayBounds(id).origin.y),
                      size: Size(width: CGDisplayBounds(id).width, height: CGDisplayBounds(id).height)))
        })
    }

    func place(_ origins: [UInt32: Point]) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        for (id, origin) in origins {
            CGConfigureDisplayOrigin(config, id, Int32(origin.x.rounded()), Int32(origin.y.rounded()))
        }
        CGCompleteDisplayConfiguration(config, .forSession)
    }
}
