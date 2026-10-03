import Foundation

/// Pure binding heuristic over live framebuffer port snapshots.
/// The device plane is the largest port of the device's own shape;
/// CarPlay is max area among the remaining eligible externals, with
/// ~720×480 as an area tie-break only.
enum ConnectedScreens {
    /// Plist CarPlay profile size — documentation / tie-break only.
    /// Runtime IOSurface dims win when areas differ.
    static let carPlayPlistSize = Size(width: 720, height: 480)

    /// `litPanel` is which of a foldable's panels the hinge has lit —
    /// `HingeAngle.litPanel`. Defaults to the cover, which is how every
    /// device boots and the only panel a single-panel device has.
    static func binding(
        kind: DisplayKind,
        ports: [FramebufferPortSnapshot],
        litPanel: IntegratedPanel = .primary
    ) throws -> DisplayBinding {
        switch kind {
        case .phone:
            return try bindPhone(ports: ports, litPanel: litPanel)
        case .carPlay:
            return try bindCarPlay(ports: ports, litPanel: litPanel)
        }
    }

    /// The exact phone panel an observation is read from, with the
    /// scale that turns its framebuffer pixels into points. A foldable
    /// needs a hinge angle to name the lit panel; a missing angle, an
    /// absent or ambiguous framebuffer, or an unusable scale is an
    /// error, never a fallback to another panel.
    static func observedPhone(
        ports: [SizedFramebufferPort], screens: [ConnectedScreenRecord], angle: HingeAngle?
    ) throws -> (binding: DisplayBinding, scale: Double, multiplePanels: Bool) {
        let integrated = screens.filter { $0.screenType == .integrated }
        let record: ConnectedScreenRecord
        if integrated.count == 1, let only = integrated.first {
            record = only
        } else {
            guard integrated.count > 1, let angle,
                let lit = integrated.first(where: { $0.panel == angle.litPanel })
            else { throw ObservedScreenError.unavailable }
            record = lit
        }
        let matches = ports.filter { $0.size == record.size }
        guard matches.count == 1, let port = matches.first,
            let scale = record.scale, scale.isFinite, scale > 0,
            record.size.width.isFinite, record.size.height.isFinite,
            record.size.width > 0, record.size.height > 0
        else { throw ObservedScreenError.unavailable }
        return (
            DisplayBinding(
                kind: .phone, connectedScreenId: record.screenId, portName: port.portName,
                size: port.size, orientation: record.uiOrientation, panel: record.panel),
            scale, integrated.count > 1
        )
    }

    private static func bindPhone(
        ports: [FramebufferPortSnapshot],
        litPanel: IntegratedPanel
    ) throws -> DisplayBinding {
        guard let winner = devicePort(in: ports, litPanel: litPanel) else {
            throw FramebufferSelectionError.noMatchingPort(.phone)
        }
        return try makeBinding(kind: .phone, port: winner)
    }

    private static func bindCarPlay(
        ports: [FramebufferPortSnapshot],
        litPanel: IntegratedPanel
    ) throws -> DisplayBinding {
        guard let device = devicePort(in: ports, litPanel: litPanel) else {
            throw FramebufferSelectionError.noMatchingPort(.carPlay)
        }
        let externals = ports.filter {
            $0 != device && FramebufferSurfacePick.acceptsExternal($0.size)
        }
        guard let best = pickBestExternal(from: externals) else {
            throw FramebufferSelectionError.noMatchingPort(.carPlay)
        }
        return try makeBinding(kind: .carPlay, port: best)
    }

    /// Which port is the device's own screen.
    ///
    /// Largest area is the usual tell and stays the tie-break, but it
    /// cannot be the whole rule: a 4K external out-measures every phone
    /// ever made, so on `[phone, 4K]` it awarded the device slot to the
    /// external — and the portrait phone left over is not a landscape
    /// external, so the CarPlay plane then reported nothing attached for
    /// a screen the user was looking at. Both planes ended up on the
    /// wrong port from one attach.
    ///
    /// Shape settles it instead. Portrait is the device's own shape and
    /// no display the External Displays menu offers is portrait, so when
    /// any portrait port exists the largest one is the device. With none
    /// — nothing attached but a landscape iPad, say — largest area is
    /// still the best answer available.
    ///
    /// A foldable breaks shape too: iPhone Duo has two portrait
    /// Integrated panels, and which one is drawn to follows the hinge —
    /// the cover while folded, the larger unfolded panel once open.
    /// Largest-portrait bound the dark one. When Connected Screens names
    /// the panels, the lit one is the device; a device with only a
    /// primary gets its primary whatever the hinge says; shape is
    /// consulted only when nothing is named.
    private static func devicePort(
        in ports: [FramebufferPortSnapshot],
        litPanel: IntegratedPanel
    ) -> FramebufferPortSnapshot? {
        if let lit = ports.first(where: { $0.panel == litPanel })
            ?? ports.first(where: { $0.panel == .primary }) {
            return lit
        }
        let portrait = ports.filter { $0.size.height > $0.size.width }
        let pool = portrait.isEmpty ? ports : portrait
        return pool.max(by: { $0.area < $1.area })
    }

    private static func pickBestExternal(
        from ports: [FramebufferPortSnapshot]
    ) -> FramebufferPortSnapshot? {
        ports.max { a, b in
            if a.area != b.area { return a.area < b.area }
            return distanceToCarPlayPlist(a) > distanceToCarPlayPlist(b)
        }
    }

    private static func distanceToCarPlayPlist(_ port: FramebufferPortSnapshot) -> Double {
        let dw = port.size.width - carPlayPlistSize.width
        let dh = port.size.height - carPlayPlistSize.height
        return dw * dw + dh * dh
    }

    private static func makeBinding(
        kind: DisplayKind,
        port: FramebufferPortSnapshot
    ) throws -> DisplayBinding {
        guard let screenId = port.connectedScreenId else {
            throw FramebufferSelectionError.screenIdUnavailable
        }
        return DisplayBinding(
            kind: kind,
            connectedScreenId: screenId,
            portName: port.portName,
            size: port.size,
            orientation: port.orientation,
            panel: port.panel
        )
    }
}
