import Foundation

/// Live identity of one connected SimulatorKit screen after resolve.
/// Creatable plist ids are not stored — only the connected id observed
/// at resolve time.
public struct DisplayBinding: Sendable, Equatable {
    public let kind: DisplayKind
    public let connectedScreenId: UInt32
    public let portName: String
    public let size: Size
    /// The guest's interface orientation on the bound screen, when it
    /// reported one. See `ConnectedScreenRecord.uiOrientation`.
    public let orientation: DeviceOrientation?
    public let panel: IntegratedPanel?

    public init(
        kind: DisplayKind,
        connectedScreenId: UInt32,
        portName: String,
        size: Size,
        orientation: DeviceOrientation? = nil,
        panel: IntegratedPanel? = nil
    ) {
        self.kind = kind
        self.connectedScreenId = connectedScreenId
        self.portName = portName
        self.size = size
        self.orientation = orientation
        self.panel = panel
    }

    /// The panel's size in points, given the device's screen scale.
    ///
    /// Accessibility frames live in this space. On a foldable the lit
    /// panel — and so the space — follows the hinge, which is why the
    /// size comes from the binding rather than the device type's single
    /// `mainScreenSize`.
    public func pointSize(scale: Double) -> Size? {
        guard scale > 0 else { return nil }
        return Size(width: size.width / scale, height: size.height / scale)
    }
}

/// Point-in-time port facts lifted from SimulatorKit for pure selection.
public struct FramebufferSnapshot: Sendable, Equatable {
    public let portName: String
    public let connectedScreenId: UInt32?
    public let size: Size
    /// Which of the device's own panels the joined Connected Screen is,
    /// when it is one. See `ConnectedScreenRecord.panel`.
    public let panel: IntegratedPanel?
    /// The joined screen's interface orientation, when reported.
    public let orientation: DeviceOrientation?

    public init(
        portName: String,
        connectedScreenId: UInt32?,
        size: Size,
        panel: IntegratedPanel? = nil,
        orientation: DeviceOrientation? = nil
    ) {
        self.portName = portName
        self.connectedScreenId = connectedScreenId
        self.size = size
        self.panel = panel
        self.orientation = orientation
    }

    public var area: Double { size.width * size.height }
}

public enum FramebufferSelectionError: Error, Equatable {
    case noMatchingFramebuffer(DisplayKind)
    case screenIdUnavailable

    /// What a caller reads when the plane will not bind.
    ///
    /// A missing CarPlay plane has two shapes and they need different
    /// hands: nothing attached at all, and attached-but-unbacked — the
    /// screen is listed under Connected Screens with no IOSurface behind
    /// it, which is what a detach-and-re-enable leaves. The second is the
    /// one that reaches here most often, and clicking CarPlay again does
    /// not clear it; only cycling the panel through Disabled does.
    public var message: String {
        switch self {
        case .noMatchingFramebuffer(.carPlay):
            return """
                no CarPlay framebuffer is attached — enable it from \
                Simulator's I/O ▸ External Displays ▸ CarPlay, or if the \
                CarPlay window is already open, cycle that menu to \
                Disabled and back to reattach a blank one
                """
        case .noMatchingFramebuffer(.phone):
            return "no framebuffer for the device's own screen — it may still be booting"
        case .screenIdUnavailable:
            return "the display is attached but has no connected screen id yet — retry once it finishes coming up"
        }
    }
}
