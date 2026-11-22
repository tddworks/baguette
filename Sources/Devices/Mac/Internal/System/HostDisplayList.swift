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

    private static func info(_ id: CGDirectDisplayID) -> MacDisplayInfo? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let text = CFUUIDCreateString(nil, uuid) as String?
        else { return nil }
        let bounds = CGDisplayBounds(id)
        let mode = CGDisplayCopyDisplayMode(id)
        let scale = mode.map { Double($0.pixelWidth) / Double(max(1, $0.width)) } ?? 1
        return MacDisplayInfo(
            id: id, uuid: text, name: name(of: id), isMain: CGDisplayIsMain(id) != 0,
            bounds: Rect(origin: Point(x: bounds.origin.x, y: bounds.origin.y),
                         size: Size(width: bounds.width, height: bounds.height)),
            pixelsPerPoint: scale)
    }

    /// The name System Settings shows ("Built-in Retina Display").
    private static func name(of id: CGDirectDisplayID) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let screen = NSScreen.screens.first { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == id }
        return screen?.localizedName ?? "Display \(id)"
    }
}
