import BaguetteDevice
import Foundation

/// Sized framebuffer port before Connected Screens ids are assigned.
struct SizedFramebuffer: Sendable, Equatable {
    let portName: String
    let size: Size
}

/// Joins live IOSurface port sizes to Connected Screens by closest
/// pixel-size distance. Each connected screen is used at most once.
enum FramebufferSnapshots {
    static func assigningScreenIds(
        ports: [SizedFramebuffer],
        screens: [ConnectedScreenRecord]
    ) -> [FramebufferSnapshot] {
        var remaining = screens
        return ports.map { port in
            guard let index = bestScreenIndex(for: port.size, in: remaining) else {
                return FramebufferSnapshot(
                    portName: port.portName,
                    connectedScreenId: nil,
                    size: port.size
                )
            }
            let screen = remaining.remove(at: index)
            return FramebufferSnapshot(
                portName: port.portName,
                connectedScreenId: screen.screenId,
                size: port.size,
                panel: screen.panel,
                orientation: screen.uiOrientation
            )
        }
    }

    private static func bestScreenIndex(
        for size: Size,
        in screens: [ConnectedScreenRecord]
    ) -> Int? {
        guard !screens.isEmpty else { return nil }
        return screens.indices.min { a, b in
            distance(size, screens[a].size) < distance(size, screens[b].size)
        }
    }

    private static func distance(_ a: Size, _ b: Size) -> Double {
        let dw = a.width - b.width
        let dh = a.height - b.height
        return dw * dw + dh * dh
    }
}
