import BaguetteDevice
import Foundation

/// The device's own display panels among its live framebuffer ports,
/// told from externals by shape alone — before Connected Screens has
/// been consulted, so it costs no guest round-trip.
///
/// Portrait is the device's own shape; nothing the External Displays
/// menu attaches is portrait, and the `tvOut` / `carPlay` / `scene`
/// decoys every device carries are all landscape. A phone has one
/// panel. A foldable (iPhone Duo) has two — cover and unfolded, both
/// portrait — and that count is what makes the phone plane's screen id
/// worth resolving: see `DisplayTouchTarget`.
enum IntegratedPanels {
    static func count(in ports: [SizedFramebuffer]) -> Int {
        ports.filter { $0.size.height > $0.size.width }.count
    }

    static func several(in ports: [SizedFramebuffer]) -> Bool {
        count(in: ports) > 1
    }
}
