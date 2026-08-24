import Foundation

/// Live identity of one connected SimulatorKit screen after resolve.
/// Creatable plist ids are not stored — only the connected id observed
/// at resolve time.
struct DisplayBinding: Sendable, Equatable {
    let kind: DisplayKind
    let connectedScreenId: UInt32
    let portName: String
    let size: Size
}

/// Point-in-time port facts lifted from SimulatorKit for pure selection.
struct FramebufferPortSnapshot: Sendable, Equatable {
    let portName: String
    let connectedScreenId: UInt32?
    let size: Size

    var area: Double { size.width * size.height }
}

enum FramebufferSelectionError: Error, Equatable {
    case noMatchingPort(DisplayKind)
    case screenIdUnavailable

    /// What a caller reads when the plane will not bind.
    ///
    /// A missing CarPlay plane has two shapes and they need different
    /// hands: nothing attached at all, and attached-but-unbacked — the
    /// screen is listed under Connected Screens with no IOSurface behind
    /// it, which is what a detach-and-re-enable leaves. The second is the
    /// one that reaches here most often, and clicking CarPlay again does
    /// not clear it; only cycling the panel through Disabled does.
    var message: String {
        switch self {
        case .noMatchingPort(.carPlay):
            return """
                no CarPlay framebuffer is attached — enable it from \
                Simulator's I/O ▸ External Displays ▸ CarPlay, or if the \
                CarPlay window is already open, cycle that menu to \
                Disabled and back to reattach a blank one
                """
        case .noMatchingPort(.phone):
            return "no framebuffer for the device's own screen — it may still be booting"
        case .screenIdUnavailable:
            return "the display is attached but has no connected screen id yet — retry once it finishes coming up"
        }
    }
}
