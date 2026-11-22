import BaguetteDevice
import CoreGraphics
import Foundation

/// Making one display main, through CoreGraphics, for this login session only
/// — never saved. Run in a `baguette main-display` process of its own: a
/// process that changes the arrangement stops seeing displays added after it.
/// Integration-only: where each display goes is `DisplayOrigins`'. Measured: a
/// display made a moment ago is listed half a second later, so this waits for
/// it to be listed, and checks it took.
enum MainDisplayMove {
    static func makeMain(_ display: UInt32) -> Bool {
        for attempt in 0..<40 {   // 2 s at most
            if CGMainDisplayID() == display {
                if attempt > 0 { log("[mac] display \(display) is main after \(attempt) tries") }
                return true
            }
            if let now = Self.origins(), now[display] != nil, let moved = DisplayOrigins.makingMain(display, in: now) {
                var config: CGDisplayConfigRef?
                if CGBeginDisplayConfiguration(&config) == .success {
                    for (id, origin) in moved {
                        CGConfigureDisplayOrigin(config, id, Int32(origin.x.rounded()), Int32(origin.y.rounded()))
                    }
                    let done = CGCompleteDisplayConfiguration(config, .forSession)
                    if attempt % 10 == 0 { log("[mac] making \(display) main: \(done.rawValue), main now \(CGMainDisplayID())") }
                }
            } else if attempt % 10 == 0 {
                log("[mac] display \(display) not listed yet (main \(CGMainDisplayID()))")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        log("[mac] display \(display) never became main (main \(CGMainDisplayID()))")
        return CGMainDisplayID() == display
    }

    private static func origins() -> [UInt32: Point]? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        return Dictionary(uniqueKeysWithValues: ids.prefix(Int(count)).map { id in
            (id, Point(x: CGDisplayBounds(id).origin.x, y: CGDisplayBounds(id).origin.y))
        })
    }
}
