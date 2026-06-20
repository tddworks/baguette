import Foundation

/// The SDK bootstrap payload — one value type that describes *what
/// parts a simulator has*. Served at
/// `/simulators/<udid>/definition.json` and read by the JS SDK's
/// `Baguette.use(udid)` to instantiate the matching `Simulator` /
/// `Screen` / `Button` / `Crown` / `Keyboard` objects on the
/// browser side.
///
/// First-principle shape: a simulator stands in for a physical
/// device; a physical device is composed of parts; this value lists
/// the parts. Optional fields (`crown`, `keyboard`, future
/// `remote`) are present only for devices that physically have
/// them — the JS facade reads each field and constructs the
/// matching part class if present, skips it otherwise. No
/// `kind:` discriminator, no capability tagged-union.
///
/// Built by the pure `compose(from:chrome:urlPrefix:)` factory.
/// Following CLAUDE.md's one-shot-fetch split, the irreducible
/// inputs (Simulator + DeviceChromeAssets) are fetched once, then
/// handed to this factory; no `@Mockable` collaborator is needed
/// because there is no conversational I/O.
struct SimulatorDefinition: Equatable, Sendable {
    let identity: Identity
    let screen:   Screen
    let buttons:  [Button]
    /// Present on devices that accept software keyboard input
    /// (iPhone, iPad). Absent on devices whose primary text input
    /// is mediated elsewhere (Apple TV's Siri Remote, watchOS's
    /// Scribble). The JS SDK instantiates a `Keyboard` part iff
    /// this field is present.
    let keyboard: Keyboard?

    /// Stable identification of *which* simulator this definition
    /// describes. `model` is the CoreSimulator device-type name
    /// (e.g. `"iPhone 17 Pro"`) — the same key chrome lookup uses,
    /// so the JS SDK can correlate `definition.json` responses
    /// across reconnects even when the user renames the device.
    struct Identity: Equatable, Sendable {
        let udid:  String
        let name:  String
        let model: String
    }

    /// The screen part: where frames land, where pointer events
    /// originate, the bezel chrome wrapped around it. Geometry is
    /// in chrome-pixel space — the JS SDK converts to CSS
    /// percentages at mount time.
    struct Screen: Equatable, Sendable {
        /// Outer composite size in chrome pixels — the `<img>` the
        /// browser fetches at `bezelImage.rest`.
        let viewport: Size
        /// Where the live frame canvas sits inside the bezel,
        /// origin + size in chrome pixels.
        let rect: Rect
        /// Inner-corner radius for the screen cutout, chrome pixels.
        let clipRadius: Double
        /// Bezel image URLs. `rest` is the merged composite (default),
        /// `bare` is the device body with buttons stripped — the
        /// SDK fetches `bare` when buttons are rendered as separate
        /// overlay parts so the bezel image and the overlays don't
        /// double-up.
        let bezelImage: BezelImage
    }

    /// Two bezel variants the SDK can ask for.
    struct BezelImage: Equatable, Sendable {
        let rest: String
        let bare: String
    }

    /// One hardware button — the JS SDK turns each of these into a
    /// `Button` part with `press({hold})` / `pressed`-image-swap /
    /// hover-translate behaviour. The definition carries everything
    /// needed to render and bind; the SDK never re-derives geometry
    /// or guesses wire codes.
    struct Button: Equatable, Sendable {
        /// Stable identity within the simulator — matches the
        /// underlying `ChromeButton.name` (`"powerButton"`,
        /// `"volumeUp"`, …) so URLs and DOM data-attrs line up.
        let id: String
        /// Wire envelope minus the user-provided `duration`. The JS
        /// SDK merges `{duration}` at press time and sends.
        let envelope: [String: String]
        /// Image URLs the browser fetches. `pressed` falls back to
        /// `rest` when the chrome ships no depressed sprite — keeps
        /// the JS swap a one-line `img.src = pressed` either way.
        let images: ButtonImages
        /// Pre-computed CSS box (percentage of the bare bezel) so
        /// the JS Button.mount sets four CSS properties verbatim —
        /// no anchor switch, no mirror formula, no halfWidth math
        /// on the client side. Anchor-specific logic lives in
        /// `compose(...)`.
        let box: Box
        /// At-rest → hover → pressed CSS transforms, image-space
        /// percentages baked in so `translate(N%)` resolves
        /// against the button's own border box. Empty `rest` means
        /// no CSS transform (the position is set by `box`).
        let transform: Transform
        /// Z-order against the bezel image. `below` means the cap
        /// pokes through a transparent slot in the bezel (every
        /// iPhone hardware button); `above` means it's layered on
        /// top (Apple Watch's action cap). Replaces the chrome's
        /// raw bool with a domain enum so callers don't have to
        /// remember which boolean direction means which behaviour.
        let z: ZOrder
    }

    struct ButtonImages: Equatable, Sendable {
        let rest:    String
        let pressed: String
    }

    /// CSS box in percentages of the bare bezel. All four fields are
    /// values the JS sets as `style.left = leftPct + '%'`, etc.
    struct Box: Equatable, Sendable {
        let leftPct:   Double
        let topPct:    Double
        let widthPct:  Double
        let heightPct: Double
    }

    /// Pre-rendered CSS `transform` strings for the three animation
    /// states. Image-space percentages mean `translate(50%, 0%)`
    /// shifts the cap by half its own width — exactly the chrome-
    /// pixel delta DeviceKit specified, regardless of the bezel's
    /// rendered size.
    struct Transform: Equatable, Sendable {
        let rest:    String
        let hover:   String
        let pressed: String
    }

    enum ZOrder: String, Sendable, Equatable {
        case below   // drawn behind the bezel — cap pokes through slot
        case above   // drawn on top of the bezel — fully visible
    }

    /// Software-keyboard capability. Presence alone signals "this
    /// device accepts text input"; the JS SDK's Keyboard part owns
    /// the W3C-code allow-list and HID resolution (the backend
    /// already maps `code → HIDUsage` via `KeyboardKey.from(wireCode:)`,
    /// so shipping that table over the wire would duplicate it).
    struct Keyboard: Equatable, Sendable {
        // Reserved for per-device variation (different layouts,
        // language hints, …). Empty today; the struct exists so
        // adding fields doesn't break the wire shape.
    }
}

extension SimulatorDefinition {

    /// JSON projection consumed by the JS SDK's `Baguette.use(udid)`
    /// bootstrap. Sorted keys keep diffs readable if a snapshot
    /// test lands later. Pure value-domain code — no I/O.
    func toJSON() -> String {
        var dict: [String: Any] = [
            "identity": [
                "udid":  identity.udid,
                "name":  identity.name,
                "model": identity.model,
            ],
            "screen": [
                "viewport": ["width": screen.viewport.width,
                             "height": screen.viewport.height],
                "rect": [
                    "x":      screen.rect.origin.x,
                    "y":      screen.rect.origin.y,
                    "width":  screen.rect.size.width,
                    "height": screen.rect.size.height,
                ],
                "clipRadius": screen.clipRadius,
                "bezelImage": [
                    "rest": screen.bezelImage.rest,
                    "bare": screen.bezelImage.bare,
                ],
            ],
            "buttons": buttons.map { b in
                [
                    "id":       b.id,
                    "envelope": b.envelope,
                    "images":   ["rest":    b.images.rest,
                                 "pressed": b.images.pressed],
                    "box": [
                        "leftPct":   b.box.leftPct,
                        "topPct":    b.box.topPct,
                        "widthPct":  b.box.widthPct,
                        "heightPct": b.box.heightPct,
                    ],
                    "transform": [
                        "rest":    b.transform.rest,
                        "hover":   b.transform.hover,
                        "pressed": b.transform.pressed,
                    ],
                    "z":        b.z.rawValue,
                ] as [String: Any]
            },
        ]
        if keyboard != nil {
            // Empty object today; reserved for per-device fields.
            // Presence alone tells the SDK to instantiate the part.
            dict["keyboard"] = [String: Any]()
        }
        let data = try! JSONSerialization.data(
            withJSONObject: dict, options: [.sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }

    /// Project a simulator + its chrome into the SDK bootstrap shape.
    /// Pure, deterministic, ~100%-unit-covered: the irreducible
    /// SimulatorKit / filesystem reads happen *before* this call
    /// (`simulators.find(udid:)`, `chromes.assets(forDeviceName:)`).
    ///
    /// `urlPrefix` is the per-udid path the route handler owns
    /// (e.g. `"/simulators/<udid>"`); the factory builds URLs by
    /// appending the well-known suffixes. Keeping the prefix as an
    /// argument means the domain stays URL-agnostic — the server
    /// decides the route layout, the factory just composes strings.
    static func compose(
        from simulator: any Simulator,
        chrome assets: DeviceChromeAssets,
        urlPrefix: String
    ) -> SimulatorDefinition {
        let chrome = assets.chrome
        // The SDK always renders the bare bezel + button overlays, so
        // every percentage reported here is against the BARE size
        // (composite minus buttonMargins). `assets.composite.size`
        // would be the merged size — wrong frame of reference for
        // overlay positioning.
        let merged = assets.composite.size
        let m = assets.buttonMargins
        let bare = Size(
            width:  merged.width  - m.left - m.right,
            height: merged.height - m.top  - m.bottom
        )
        let screenRect = chrome.screenRect(in: bare)

        return SimulatorDefinition(
            identity: Identity(
                udid: simulator.udid,
                name: simulator.name,
                model: simulator.deviceTypeName
            ),
            screen: Screen(
                viewport:   bare,
                rect:       screenRect,
                clipRadius: chrome.innerCornerRadius,
                bezelImage: BezelImage(
                    rest: "\(urlPrefix)/bezel.png",
                    bare: "\(urlPrefix)/bezel.png?buttons=false"
                )
            ),
            buttons: chrome.buttons.compactMap { b in
                Button(
                    fromChrome: b,
                    imageSize: assets.buttonImages[b.name]?.size,
                    bareSize: bare,
                    urlPrefix: urlPrefix
                )
            },
            keyboard: Self.keyboard(for: chrome.identifier)
        )
    }

    /// Devices whose primary text input is mediated by a companion
    /// surface (Apple TV's Siri Remote) or a non-keyboard modality
    /// (watchOS Scribble) don't get a Keyboard part — the JS SDK
    /// then doesn't attach any keydown listeners. Anything else
    /// gets the standard part; the JS owns the W3C-code whitelist.
    fileprivate static func keyboard(for identifier: String) -> Keyboard? {
        let id = identifier.lowercased()
        if id.hasPrefix("tv") { return nil }
        if id.hasPrefix("watch") { return nil }
        return Keyboard()
    }
}

extension SimulatorDefinition.Button {

    /// Project one `ChromeButton` into the SDK's `Button` shape.
    /// Returns `nil` for chrome inputs whose `name` doesn't map to
    /// a known wire button — keeps the SDK surface honest (no
    /// inert "tooltip-only" buttons; if it isn't wired, it isn't
    /// in the definition).
    init?(
        fromChrome b: ChromeButton,
        imageSize: Size?,
        bareSize: Size,
        urlPrefix: String
    ) {
        guard let wire = Self.wireButton(for: b.name) else { return nil }
        // The button overlay needs a real image size to size its
        // wrapper. Falling back to a hardcoded default would let the
        // SDK ship visually-broken overlays; better to drop the
        // button than render it wrong. Buttons with no chrome image
        // wouldn't render today either (legacy bezel-buttons.js
        // bailed in `_buildButton` when `imageUrl` was missing).
        guard let imageSize else { return nil }

        self.init(
            id: b.name,
            envelope: ["type": "button", "button": wire],
            images: SimulatorDefinition.ButtonImages(
                rest:    "\(urlPrefix)/chrome-button/\(b.name).png",
                pressed: b.imageDownName != nil
                    ? "\(urlPrefix)/chrome-button/\(b.name)-down.png"
                    : "\(urlPrefix)/chrome-button/\(b.name).png"
            ),
            box: Self.box(for: b, imageSize: imageSize, bareSize: bareSize),
            transform: Self.transform(for: b, imageSize: imageSize),
            z: b.onTop ? .above : .below
        )
    }

    /// Anchor-specific positioning, ported verbatim from the legacy
    /// `bezel-buttons.js` `_size()` switch so the visual position
    /// is pixel-for-pixel identical to the static-composite bake-in
    /// that Apple's DeviceKit ships. The mirror formula on the
    /// `.right` arm (`restX = 2·normal − rollover`) keeps the cap
    /// inset by exactly one rollover-delta so the hover translate
    /// lands it at the rollover position — same UX as macOS Tahoe
    /// Simulator's button animation.
    fileprivate static func box(
        for b: ChromeButton,
        imageSize: Size,
        bareSize: Size
    ) -> SimulatorDefinition.Box {
        let iw = imageSize.width, ih = imageSize.height
        let bareW = bareSize.width, bareH = bareSize.height
        let widthPct  = iw / bareW * 100
        let heightPct = ih / bareH * 100
        let halfWPct  = iw / 2 / bareW * 100
        let normal = b.normalOffset
        let rollover = b.rolloverOffset

        switch b.anchor {
        case .left:
            // Centre at rollover.x, top at rollover.y — the cap
            // pokes inward from the bezel's left rail at-rest.
            let cxPct = rollover.x / bareW * 100
            let tyPct = rollover.y / bareH * 100
            return SimulatorDefinition.Box(
                leftPct: cxPct - halfWPct, topPct: tyPct,
                widthPct: widthPct, heightPct: heightPct
            )
        case .right:
            // Mirror the rollover-delta inward so hover translate
            // (rollover − normal) lands the cap at the rollover
            // position. For caps without hover (normal == rollover)
            // the formula collapses to `normalOffset` and the cap
            // stays fixed.
            let restX = 2 * normal.x - rollover.x
            let restY = 2 * normal.y - rollover.y
            return SimulatorDefinition.Box(
                leftPct: (bareW + restX) / bareW * 100,
                topPct:  restY / bareH * 100,
                widthPct: widthPct, heightPct: heightPct
            )
        case .top:
            // Mirror the rollover-delta inward — same rationale as the
            // `.right` arm above. chrome.json's normalOffset.y is the
            // hover position (cap popped further up past the body's top
            // edge); at-rest mirrors that delta DOWNWARD so the cap
            // mostly hides inside the body and only `imageH - restY`
            // chrome-pixels protrude above the top edge. The cap is
            // positioned with its TOP edge at `restY - imageH` in bare
            // coords (NEGATIVE — above the bare top), so the SDK's
            // z=below scheme leaves the visible portion uncovered.
            //
            // For align=.trailing / .leading, offset.x is the inset
            // from the body's trailing / leading edge to the cap's
            // TRAILING / LEADING edge — not its centre. This matches
            // how `.right` with align=.leading takes offset.y as the
            // inset to the cap's leading (top) edge, not its centre.
            // Treating offset.x as the cap's centre drifts the cap
            // half its image width too far towards the body interior
            // (visible on the iPad Pro 13-inch (M4) power button —
            // it landed 32 px right of where Apple positions it).
            let restX = 2 * normal.x - rollover.x
            let restY = 2 * normal.y - rollover.y
            let leftX: Double
            switch b.align {
            case .trailing: leftX = bareW + restX - imageSize.width
            case .leading:  leftX = restX
            }
            let leftPctTop = leftX / bareW * 100
            let tyPct = (restY - imageSize.height) / bareH * 100
            return SimulatorDefinition.Box(
                leftPct: leftPctTop, topPct: tyPct,
                widthPct: widthPct, heightPct: heightPct
            )
        case .bottom:
            // Symmetric to `.top`: cap protrudes DOWNWARD past the body
            // bottom edge. At-rest position uses the mirrored restY so
            // only `-restY` chrome-pixels poke below the bare bottom.
            // Same edge-aligned offset.x semantics as `.top`.
            let restX = 2 * normal.x - rollover.x
            let restY = 2 * normal.y - rollover.y
            let leftX: Double
            switch b.align {
            case .trailing: leftX = bareW + restX - imageSize.width
            case .leading:  leftX = restX
            }
            let leftPctBottom = leftX / bareW * 100
            let tyPct = (bareH + restY) / bareH * 100
            return SimulatorDefinition.Box(
                leftPct: leftPctBottom, topPct: tyPct,
                widthPct: widthPct, heightPct: heightPct
            )
        }
    }

    /// Hover / pressed translates expressed as percentages of the
    /// button image's OWN width/height — so CSS `translate(N%)`
    /// (which resolves against the element's border box, not its
    /// parent) moves the cap by exactly the chrome-pixel delta
    /// DeviceKit specified. Without dividing by image size the
    /// translate would be ~1/30th the intended distance.
    fileprivate static func transform(
        for b: ChromeButton, imageSize: Size
    ) -> SimulatorDefinition.Transform {
        let outDx = (b.rolloverOffset.x - b.normalOffset.x) / imageSize.width  * 100
        let outDy = (b.rolloverOffset.y - b.normalOffset.y) / imageSize.height * 100
        return SimulatorDefinition.Transform(
            rest:    "none",
            hover:   "translate(\(formatPct(outDx))%, \(formatPct(outDy))%)",
            pressed: "translate(\(formatPct(-outDx))%, \(formatPct(-outDy))%)"
        )
    }

    /// Drop the trailing `.0` so integer-valued percents serialise
    /// cleanly (`50%` not `50.0%`). Anything else keeps its
    /// fractional digits — `0.75%` stays as is.
    fileprivate static func formatPct(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }

    /// Apple's chrome.json `name` is already the hyphenated
    /// lowercase form (`"power"`, `"volume-up"`, `"action"`,
    /// `"digital-crown"`, `"side-button"`, …) — same vocabulary
    /// the GestureRegistry's `DeviceButton` enum speaks. The
    /// mapping is the identity for every wired name today, but
    /// the switch stays as the explicit allow-list: an unknown
    /// name returns nil so the overlay isn't rendered for
    /// gestures we don't dispatch. One source of truth, replacing
    /// the JS `WIRE_BUTTON` map that used to live in
    /// `bezel-buttons.js`.
    private static func wireButton(for chromeName: String) -> String? {
        switch chromeName {
        case "power", "volume-up", "volume-down", "action",
             "home", "lock",
             "digital-crown", "side-button", "left-side-button":
            return chromeName
        default:
            return nil
        }
    }
}
