import Foundation
import Mockable

/// Per-simulator chrome (bezel) lookup. Reads Apple's own DeviceKit
/// assets so coverage is automatic for every device CoreSimulator
/// ships — no hand-curated PNG/insets table to keep in sync.
///
/// Kept separate from `Simulators` because the concerns don't
/// overlap: `Simulators` drives CoreSimulator runtime, `Chromes`
/// reads filesystem assets. UI / HTTP code that wants the layout
/// asks `chromes.assets(for: simulator)` directly.
///
/// `@Mockable` so command-layer tests can drive HTTP handlers
/// without touching `/Library/Developer/`.
@Mockable
protocol Chromes: AnyObject, Sendable {
    /// Resolve the chrome layout + rasterized composite for a
    /// device by its CoreSimulator type name (e.g. `"iPhone 17 Pro"`).
    /// Device name is the natural lookup key — every simulator with
    /// that device-type shares the same chrome bundle, so keying on
    /// UDID would cache identical results redundantly.
    ///
    /// Returns `nil` when no chrome bundle covers the device
    /// (e.g. Apple TV / watchOS) or any underlying asset fails to
    /// load. The caller decides whether to fall back to a plain
    /// stream.
    func assets(forDeviceName deviceName: String) -> DeviceChromeAssets?
}

/// What `Chromes` hands back: the parsed layout from `chrome.json`
/// paired with the rasterized composite PDF that the front end
/// renders as the bezel image. Kept as one value because the
/// composite size is needed to interpret the layout's pixel-space
/// rects — splitting the two would invite drift between them.
///
/// `composite` may be the merged bezel (device body + buttons baked
/// behind it). When it is, `buttonMargins` records how far the merged
/// canvas was expanded around the original chrome.json composite.
/// `chrome` is *always* the parsed value — `screenInsets`,
/// `bezelWidth`, and `innerCornerRadius` stay at the chrome.json
/// values regardless of any margin growth, so the screen's rounded
/// corner doesn't change when buttons are layered in.
struct DeviceChromeAssets: Sendable, Equatable {
    let chrome: DeviceChrome
    let composite: ChromeImage
    /// The device body alone — same composite *without* the buttons
    /// merged in. Always present (equals `composite` when the chrome
    /// has no buttons). Served by `bezel.png?buttons=false` so the
    /// front end can render the buttons as separate, animatable DOM
    /// elements layered over a bare bezel.
    let bareComposite: ChromeImage
    /// Per-button rasterized PNGs, keyed by `ChromeButton.name`
    /// (e.g. `"powerButton"`, `"actionButton"`, `"volumeUp"`). Served
    /// by `/simulators/<udid>/chrome-button/<name>.png`. Empty when
    /// the chrome carries no buttons.
    let buttonImages: [String: ChromeImage]
    /// Overshoot of buttons past each edge of the original composite,
    /// in chrome pixels. All zero when no buttons (or buttons fit
    /// inside the device body).
    let buttonMargins: Insets

    init(
        chrome: DeviceChrome,
        composite: ChromeImage,
        bareComposite: ChromeImage? = nil,
        buttonImages: [String: ChromeImage] = [:],
        buttonMargins: Insets = Insets(top: 0, left: 0, bottom: 0, right: 0)
    ) {
        self.chrome = chrome
        self.composite = composite
        // Default `bareComposite` to `composite` when not supplied —
        // covers chromes with no buttons (the merged and bare bezels
        // are identical) and keeps existing test fixtures working
        // without changes.
        self.bareComposite = bareComposite ?? composite
        self.buttonImages = buttonImages
        self.buttonMargins = buttonMargins
    }

    /// Layout JSON for the `/simulators/<udid>/chrome.json` endpoint.
    /// Reports the *merged* composite size and the screen rect shifted
    /// by `buttonMargins` (so the front end's percentage math lines up
    /// with the rendered bezel.png), but emits the parsed chrome's
    /// `innerCornerRadius` directly — the screen corner curve doesn't
    /// stretch when buttons add canvas around the device body.
    ///
    /// `buttonImageURLPrefix` lets the route handler inject an
    /// `imageUrl` per button entry — e.g. pass
    /// `"/simulators/<udid>/chrome-button/"` and each button gets
    /// `imageUrl: "<prefix><name>.png"`. Pass `nil` (or omit) to
    /// emit the legacy shape with no `imageUrl` field. The domain
    /// stays URL-agnostic; the server owns the URL template.
    func layoutJSON(buttonImageURLPrefix: String? = nil) -> String {
        let originalCompositeSize = Size(
            width:  composite.size.width  - buttonMargins.left - buttonMargins.right,
            height: composite.size.height - buttonMargins.top  - buttonMargins.bottom
        )
        let baseScreen = chrome.screenRect(in: originalCompositeSize)
        let buttons: [[String: Any]] = chrome.buttons.map { b in
            var entry = b.json
            if let prefix = buttonImageURLPrefix {
                entry["imageUrl"] = "\(prefix)\(b.name).png"
            }
            return entry
        }
        let dict: [String: Any] = [
            "identifier": chrome.identifier,
            "outerCornerRadius": chrome.outerCornerRadius,
            "innerCornerRadius": chrome.innerCornerRadius,
            "composite": [
                "width":  composite.size.width,
                "height": composite.size.height,
            ],
            "screen": [
                "x":      baseScreen.origin.x + buttonMargins.left,
                "y":      baseScreen.origin.y + buttonMargins.top,
                "width":  baseScreen.size.width,
                "height": baseScreen.size.height,
            ],
            "buttons": buttons,
        ]
        let data = try! JSONSerialization.data(
            withJSONObject: dict, options: [.sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }
}

/// PNG bytes plus the image's pixel size. Chrome assets are
/// rasterized once per chrome identifier and reused across all
/// simulators that share that bundle, so allocating one of these is
/// rare enough that holding both fields together is fine.
struct ChromeImage: Sendable, Equatable {
    let data: Data
    let size: Size
}
