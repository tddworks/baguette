import BaguetteDevice
import Foundation

/// How each Mac display looks until a frame is picked: no frame. Its bezel
/// is a clear picture the display's own size (in points), the screen filling
/// it — so the page draws the stream alone, at the display's shape, the way
/// it draws any bezel. A display is found by its name, which is its model.
public final class MacDisplayLooks: Chromes, @unchecked Sendable {
    private let displays: @Sendable () -> [MacDisplayInfo]
    private let clearPicture: @Sendable (Size) -> Data?

    public init(displays: @escaping @Sendable () -> [MacDisplayInfo],
         clearPicture: @escaping @Sendable (Size) -> Data? = ClearPicture.png) {
        self.displays = displays
        self.clearPicture = clearPicture
    }

    public func assets(forDeviceName name: String) -> DeviceChromeAssets? {
        guard let display = displays().first(where: { $0.name == name }) else { return nil }
        let size = display.bounds.size
        guard let picture = clearPicture(size) else { return nil }
        let unframed = DeviceChrome(
            identifier: name, screenInsets: Insets(top: 0, left: 0, bottom: 0, right: 0),
            outerCornerRadius: 0, buttons: [], compositeImageName: nil)
        return DeviceChromeAssets(chrome: unframed, composite: ChromeImage(data: picture, size: size))
    }

    public func assets(forDeviceName name: String, panel: IntegratedPanel) -> DeviceChromeAssets? {
        panel == .primary ? assets(forDeviceName: name) : nil
    }

    public func panels(forDeviceName name: String) -> [IntegratedPanel] {
        displays().contains { $0.name == name } ? [.primary] : []
    }
}
