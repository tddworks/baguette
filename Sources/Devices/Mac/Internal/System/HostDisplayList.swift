import AppKit
import BaguetteDevice
import CoreGraphics

/// The displays attached to this Mac, as CoreGraphics lists them — none of
/// this asks for Screen Recording. Integration-only: the decisions are in
/// `MacDisplays` and `MacDisplayInfo`.
enum HostDisplayList {
    static func all() -> [MacDisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).compactMap(info)
    }

    /// Where display `id` is on the desktop now — cheap enough for every gesture; nil when it's gone.
    @Sendable static func bounds(of id: UInt32) -> Rect? {
        let bounds = CGDisplayBounds(id)
        guard bounds.width > 0 else { return nil }
        return Rect(origin: Point(x: bounds.origin.x, y: bounds.origin.y), size: Size(width: bounds.width, height: bounds.height))
    }

    /// The main display now: where the menu bar, the Dock and new windows are.
    @Sendable static func main() -> UInt32 { CGMainDisplayID() }

    /// Whether the Mac lists the display `id` now.
    @Sendable static func isListed(_ id: UInt32) -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains(id)
    }

    private static func info(_ id: CGDirectDisplayID) -> MacDisplayInfo? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let text = CFUUIDCreateString(nil, uuid) as String?
        else { return nil }
        let bounds = CGDisplayBounds(id)
        return MacDisplayInfo(
            id: id, uuid: text, name: name(of: id), isMain: CGDisplayIsMain(id) != 0,
            bounds: Rect(origin: Point(x: bounds.origin.x, y: bounds.origin.y),
                         size: Size(width: bounds.width, height: bounds.height)))
    }

    /// The name System Settings shows ("Built-in Retina Display").
    private static func name(of id: CGDirectDisplayID) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let screen = NSScreen.screens.first { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == id }
        return screen?.localizedName ?? "Display \(id)"
    }
}
