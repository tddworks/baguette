import BaguetteDevice
import Foundation

/// The Mac family as a source of `Devices`: each display attached to this Mac,
/// as CoreGraphics lists it — listing never asks for Screen Recording; only
/// watching a display does. A display is named by its own UUID, the same
/// across reboots. Reached only when asked for (`serve --share-mac`,
/// `list --mac`, or a display's UUID given to `--udid`): it shows, and
/// drives, this Mac. Design: docs/features/mac-screen/design.md.
final class MacDisplays: Devices, @unchecked Sendable {
    private let displays: @Sendable () -> [MacDisplayInfo]
    private let feed: @Sendable () -> any DisplayFeed
    private let events: any HostEvents
    private let madePixels: @Sendable (String) -> Size?

    /// `madePixels`: the pixels of a display baguette made itself (a share's),
    /// by its UUID — what it is captured at.
    init(displays: @escaping @Sendable () -> [MacDisplayInfo],
         feed: @escaping @Sendable () -> any DisplayFeed,
         events: any HostEvents,
         madePixels: @escaping @Sendable (String) -> Size? = { _ in nil }) {
        self.displays = displays
        self.feed = feed
        self.events = events
        self.madePixels = madePixels
    }

    /// This Mac's own displays, watched through ScreenCaptureKit and driven
    /// through the window server.
    static func onThisMac(madePixels: @escaping @Sendable (String) -> Size? = { _ in nil }) -> MacDisplays {
        MacDisplays(displays: { HostDisplayList.all() }, feed: { ScreenCaptureKitFeed() }, events: CGEventHostEvents(),
                    madePixels: madePixels)
    }

    var all: [any Device] {
        displays().map { MacDisplay(info: $0, feed: feed, events: events, madePixels: madePixels) }
    }

    func find(id: DeviceID) throws -> (any Device)? {
        all.first { $0.id == id }
    }
}

/// A Mac display as a `Device`, and the one place deciding what it can do:
/// be watched (its screen, through ScreenCaptureKit) and driven (a finger as
/// the mouse, the Mac's keyboard and scroll, through the window server). It
/// has no buttons to press.
struct MacDisplay: Device {
    let info: MacDisplayInfo
    let feed: @Sendable () -> any DisplayFeed
    let events: any HostEvents
    var madePixels: @Sendable (String) -> Size? = { _ in nil }

    var id: DeviceID { DeviceID(info.uuid) }
    var name: String { info.name }
    var kind: DeviceKind { DeviceKind(platform: .macOS, reality: .physical, model: info.name) }
    var state: DeviceState { .ready }

    var abilities: Abilities {
        var abilities = Abilities(device: name)
        let (info, feed, madePixels) = (info, feed, madePixels)
        let input = MacInput(display: DisplayEvents(bounds: info.bounds), events: events)
        abilities.register(.screen) { MacScreen(display: info, feed: feed(), madePixels: madePixels(info.uuid)) }
        abilities.register(.touch) { input }
        abilities.register(.scroll) { input }
        abilities.register(.key) { input }
        abilities.register(.typing) { input }
        return abilities
    }
}
