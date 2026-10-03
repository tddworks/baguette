import Foundation

/// Identity and raw pixels of the connected display an observation was
/// read from: the `connectedScreenId`, the lit panel of a foldable, and
/// the framebuffer's pixel size. Reported alongside AX results so a
/// client can tell that a later observation still describes the same
/// panel; never a HID target a client supplies.
struct ScreenTarget: Equatable, Sendable {
    let screenId: UInt32
    let litPanel: IntegratedPanel?
    let pixelSize: Size

    var dictionary: [String: Any] {
        [
            "screenId": screenId,
            "litPanel": litPanel.map { $0 == .primary ? "primary" : "secondary" } as Any? ?? NSNull(),
            "pixelSize": ["width": pixelSize.width, "height": pixelSize.height],
        ]
    }
}

/// A display could not report a fresh, unambiguous screen: the panel
/// selection, framebuffer or orientation was unavailable.
enum ObservedScreenError: LocalizedError, Equatable {
    case unavailable

    var errorDescription: String? {
        "the display cannot provide a fresh screen target"
    }
}
