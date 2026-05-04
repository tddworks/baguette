import Foundation

/// Bezel + button layout for a simulator device, sourced from Apple's
/// own DeviceKit chrome bundles (no hand-curated PNGs). One value
/// describes one device family — the same chrome (e.g. `phone11`) can
/// back several simulator names.
///
/// Holds only the geometry that comes from `chrome.json`: the screen
/// insets carved out of the device body, the device's outer corner
/// radius, and the input buttons (action / volume / power) with their
/// anchor + offset positioning. The composite image's pixel size is
/// supplied at consumption time (`screenRect(in:)`, `layoutJSON(...)`)
/// because that's measured from the rasterized PDF in Infrastructure,
/// not from the JSON.
struct DeviceChrome: Equatable, Sendable {
    let identifier: String
    let screenInsets: Insets
    let outerCornerRadius: Double
    let buttons: [ChromeButton]
    /// Basename of the pre-built composite PDF inside the chrome
    /// bundle, e.g. `"PhoneComposite"`. `nil` when the bundle only
    /// ships 9-slice pieces — the loader falls back to the slice path.
    let compositeImageName: String?
    /// 9-slice piece names (4 corners, 4 edges, 1 inner screen).
    /// Populated when `chrome.json` carries the full set; `nil` when
    /// any piece is missing. Bundles with a baked composite still
    /// publish slice names, so the slice acts as a fallback path even
    /// when `compositeImageName` is set.
    let slice: DeviceChromeSlice?

    init(
        identifier: String,
        screenInsets: Insets,
        outerCornerRadius: Double,
        buttons: [ChromeButton],
        compositeImageName: String?,
        slice: DeviceChromeSlice? = nil
    ) {
        self.identifier = identifier
        self.screenInsets = screenInsets
        self.outerCornerRadius = outerCornerRadius
        self.buttons = buttons
        self.compositeImageName = compositeImageName
        self.slice = slice
    }

    /// Width of the bezel surrounding the screen — the larger of the
    /// horizontal and vertical insets, used to derive the inner corner
    /// radius. Phones have symmetric bezels in practice; we still take
    /// the max so an unusual device with thicker top inset (a tablet
    /// with a status bar) gets a visually correct screen radius.
    var bezelWidth: Double {
        max(screenInsets.left, screenInsets.top)
    }

    /// Corner radius of the *screen* cutout. The chrome JSON only
    /// publishes the outer body radius; subtracting one bezel width
    /// gives the inner radius that should clip the streamed frame. Floor
    /// at zero — some chromes have square outer corners (where bezel
    /// would push the radius negative).
    var innerCornerRadius: Double {
        max(outerCornerRadius - bezelWidth, 0)
    }

    /// Where the screen sits inside a composite image of the given
    /// pixel size. Origin is the top-left inset; the size is the
    /// composite minus left+right and top+bottom insets.
    func screenRect(in compositeSize: Size) -> Rect {
        Rect(
            origin: Point(x: screenInsets.left, y: screenInsets.top),
            size: Size(
                width: compositeSize.width - screenInsets.left - screenInsets.right,
                height: compositeSize.height - screenInsets.top - screenInsets.bottom
            )
        )
    }

    /// JSON projection consumed by the simulator UI — same shape the
    /// `/api/sim/<udid>/layout` endpoint will return. Sized to a
    /// concrete composite so the front end gets pixel-space rects ready
    /// to position `<div>`s without re-doing the inset math.
    func layoutJSON(compositeSize: Size) -> String {
        let screen = screenRect(in: compositeSize)
        let dict: [String: Any] = [
            "identifier": identifier,
            "outerCornerRadius": outerCornerRadius,
            "innerCornerRadius": innerCornerRadius,
            "composite": ["width": compositeSize.width, "height": compositeSize.height],
            "screen": [
                "x": screen.origin.x, "y": screen.origin.y,
                "width": screen.size.width, "height": screen.size.height,
            ],
            "buttons": buttons.map(\.json),
        ]
        // Sorted keys keep diffs readable if a snapshot test ever lands.
        let data = try! JSONSerialization.data(
            withJSONObject: dict, options: [.sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - parsing

    /// Parse a `chrome.json` payload from a DeviceKit bundle. Strips
    /// the `com.apple.dt.devicekit.chrome.` prefix so the identifier we
    /// expose matches the directory name (`phone11`, `tablet5`, …).
    static func parsing(json data: Data) throws -> DeviceChrome {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw DeviceChromeParseError.malformedJSON
        }
        guard let dict = raw as? [String: Any] else {
            throw DeviceChromeParseError.malformedJSON
        }
        guard let fullID = dict["identifier"] as? String else {
            throw DeviceChromeParseError.missingIdentifier
        }

        let prefix = "com.apple.dt.devicekit.chrome."
        let identifier = fullID.hasPrefix(prefix)
            ? String(fullID.dropFirst(prefix.count))
            : fullID

        let images = dict["images"] as? [String: Any] ?? [:]
        let sizing = images["sizing"] as? [String: Any] ?? [:]
        let insets = Insets(
            top:    coerceDouble(sizing["topHeight"]),
            left:   coerceDouble(sizing["leftWidth"]),
            bottom: coerceDouble(sizing["bottomHeight"]),
            right:  coerceDouble(sizing["rightWidth"])
        )

        let paths = dict["paths"] as? [String: Any] ?? [:]
        let border = paths["simpleOutsideBorder"] as? [String: Any] ?? [:]
        let outerRadius = coerceDouble(border["cornerRadiusX"])

        let inputs = dict["inputs"] as? [[String: Any]] ?? []
        let buttons = inputs.compactMap(ChromeButton.init(json:))

        return DeviceChrome(
            identifier: identifier,
            screenInsets: insets,
            outerCornerRadius: outerRadius,
            buttons: buttons,
            compositeImageName: images["composite"] as? String,
            slice: DeviceChromeSlice(json: images)
        )
    }
}

/// Names of the nine PDF assets that compose a bezel when a bundle
/// doesn't ship a baked `Composite.pdf`. Eight pieces wrap the device
/// body (4 corners + 4 edges); `screen` defines the inner cutout area
/// — its bounding box, plus the chrome's `screenInsets`, drives the
/// composed canvas size.
struct DeviceChromeSlice: Equatable, Sendable {
    let topLeft: String
    let top: String
    let topRight: String
    let right: String
    let bottomRight: String
    let bottom: String
    let bottomLeft: String
    let left: String
    let screen: String

    init(
        topLeft: String, top: String, topRight: String,
        right: String,
        bottomRight: String, bottom: String, bottomLeft: String,
        left: String,
        screen: String
    ) {
        self.topLeft = topLeft
        self.top = top
        self.topRight = topRight
        self.right = right
        self.bottomRight = bottomRight
        self.bottom = bottom
        self.bottomLeft = bottomLeft
        self.left = left
        self.screen = screen
    }

    /// All-or-nothing parse: any missing key → `nil`. Keeps callers
    /// simple — they branch on `slice != nil` instead of probing each
    /// field, and a partial bundle can't accidentally produce a
    /// half-drawn bezel.
    init?(json images: [String: Any]) {
        guard
            let topLeft = images["topLeft"] as? String,
            let top = images["top"] as? String,
            let topRight = images["topRight"] as? String,
            let right = images["right"] as? String,
            let bottomRight = images["bottomRight"] as? String,
            let bottom = images["bottom"] as? String,
            let bottomLeft = images["bottomLeft"] as? String,
            let left = images["left"] as? String,
            let screen = images["screen"] as? String
        else { return nil }

        self.init(
            topLeft: topLeft, top: top, topRight: topRight,
            right: right,
            bottomRight: bottomRight, bottom: bottom, bottomLeft: bottomLeft,
            left: left,
            screen: screen
        )
    }
}

/// JSONSerialization wraps every numeric in NSNumber, which bridges to
/// Double on Apple platforms regardless of the JSON literal's shape —
/// so one cast covers integer and floating literals alike. Missing /
/// non-numeric values fall back to zero so callers stay terse.
fileprivate func coerceDouble(_ any: Any?) -> Double {
    (any as? Double) ?? 0
}

/// One button overlaid on the device body — action / volume / power.
/// Drawn as a separate PDF asset on top of the composite, anchored to
/// an edge with a normalised offset.
struct ChromeButton: Equatable, Sendable {
    enum Anchor: String, Sendable, Equatable {
        case left, right, top, bottom
    }
    enum Align: String, Sendable, Equatable {
        case leading, trailing
    }

    let name: String
    let imageName: String
    /// Optional pressed-state asset (chrome.json's `imageDown`).
    /// Apple ships a darker / depressed sprite per button; the
    /// actionable-bezel UI swaps to it on `mousedown`. `nil` when
    /// the chrome doesn't carry a depressed variant — callers fall
    /// back to the at-rest `imageName`.
    let imageDownName: String?
    /// How the depressed sprite should be drawn relative to the
    /// at-rest one (chrome.json's `imageDownDrawMode`). Apple's
    /// known values: `"replace"` (swap entirely) and absent
    /// (overlay). Stored verbatim so we don't bake an assumption
    /// here; consumers interpret it. `nil` when no down asset.
    let imageDownDrawMode: String?
    let anchor: Anchor
    let align: Align
    /// At-rest position (chrome.json's `offsets.normal`). The button
    /// cap sits flush with the device side; only the small overshoot
    /// past the bezel edge is visible.
    let normalOffset: Point
    /// Hover / pressed position (chrome.json's `offsets.rollover`).
    /// Pops the cap outward by a few chrome pixels — the actionable-
    /// bezel UI animates between `normalOffset` and `rolloverOffset`
    /// on hover.
    let rolloverOffset: Point
    /// Convenience: today's static-composite path (LiveChromes
    /// bake-in) wants a single offset to position the button image
    /// inside the merged canvas. The merged image is meant to depict
    /// the rollover / pressed state, so this returns the rollover
    /// offset. New callers should pick `normalOffset` /
    /// `rolloverOffset` explicitly.
    var offset: Point { rolloverOffset }
    /// Z-order against the device composite. `true` = drawn ON TOP of
    /// the bezel (Apple Watch's orange action button, the digital crown
    /// and side button on watch ≤ watch5b/5s where they aren't baked
    /// into the composite). `false` = drawn BEHIND the composite, so
    /// only the portion overshooting the bezel edge stays visible
    /// (every iPhone power / volume button). Sourced from chrome.json's
    /// `inputs[].onTop`; defaults to `false` to match the iPhone case.
    let onTop: Bool

    var json: [String: Any] {
        var dict: [String: Any] = [
            "name": name,
            "imageName": imageName,
            "anchor": anchor.rawValue,
            "align": align.rawValue,
            // Legacy `offset` keeps the rollover value so existing
            // (static-composite) front-end code keeps working. New
            // code should read `normalOffset` / `rolloverOffset`
            // directly to drive the at-rest → hover animation.
            "offset": ["x": rolloverOffset.x, "y": rolloverOffset.y],
            "normalOffset":   ["x": normalOffset.x,   "y": normalOffset.y],
            "rolloverOffset": ["x": rolloverOffset.x, "y": rolloverOffset.y],
            "onTop": onTop,
        ]
        if let imageDownName {
            dict["imageDownName"] = imageDownName
        }
        if let imageDownDrawMode {
            dict["imageDownDrawMode"] = imageDownDrawMode
        }
        return dict
    }

    init(
        name: String, imageName: String,
        imageDownName: String? = nil,
        imageDownDrawMode: String? = nil,
        anchor: Anchor, align: Align,
        normalOffset: Point,
        rolloverOffset: Point? = nil,
        onTop: Bool = false
    ) {
        self.name = name
        self.imageName = imageName
        self.imageDownName = imageDownName
        self.imageDownDrawMode = imageDownDrawMode
        self.anchor = anchor
        self.align = align
        self.normalOffset = normalOffset
        // When only one variant is supplied, the button has no
        // distinct hover state — both offsets point at the same
        // place so animation code becomes a no-op rather than
        // requiring a nil branch.
        self.rolloverOffset = rolloverOffset ?? normalOffset
        self.onTop = onTop
    }

    /// Convenience initialiser preserving the legacy single-offset
    /// shape. Older callers (and a few tests) construct buttons with
    /// just one Point and don't care about the hover-state animation;
    /// this routes them to both offsets so the value is well-defined.
    init(
        name: String, imageName: String,
        imageDownName: String? = nil,
        imageDownDrawMode: String? = nil,
        anchor: Anchor, align: Align,
        offset: Point,
        onTop: Bool = false
    ) {
        self.init(
            name: name, imageName: imageName,
            imageDownName: imageDownName,
            imageDownDrawMode: imageDownDrawMode,
            anchor: anchor, align: align,
            normalOffset: offset, rolloverOffset: offset,
            onTop: onTop
        )
    }

    /// Build from one entry of `inputs[]`. Returns nil for entries
    /// missing required fields rather than throwing — chrome.json may
    /// carry decorative inputs we don't model (e.g. status LEDs).
    init?(json dict: [String: Any]) {
        guard let name = dict["name"] as? String,
              let imageName = dict["image"] as? String
        else { return nil }

        let anchor = (dict["anchor"] as? String).flatMap(Anchor.init(rawValue:)) ?? .left
        let align  = (dict["align"]  as? String).flatMap(Align.init(rawValue:))  ?? .leading

        // Retain BOTH offsets so the actionable-bezel UI can animate
        // between at-rest (normal) and popped-out (rollover) on
        // hover. Either variant alone falls back to the other so the
        // pair is always well-formed.
        let offsets = dict["offsets"] as? [String: Any]
        let normalDict   = (offsets?["normal"]   as? [String: Any])
        let rolloverDict = (offsets?["rollover"] as? [String: Any])
        let primary = normalDict ?? rolloverDict ?? [:]
        let normal = Point(
            x: coerceDouble(primary["x"]),
            y: coerceDouble(primary["y"])
        )
        let secondary = rolloverDict ?? normalDict ?? [:]
        let rollover = Point(
            x: coerceDouble(secondary["x"]),
            y: coerceDouble(secondary["y"])
        )
        self.init(
            name: name, imageName: imageName,
            imageDownName: dict["imageDown"] as? String,
            imageDownDrawMode: dict["imageDownDrawMode"] as? String,
            anchor: anchor, align: align,
            normalOffset: normal,
            rolloverOffset: rollover,
            onTop: dict["onTop"] as? Bool ?? false
        )
    }
}

/// Failures while parsing a `chrome.json` payload. Identifier missing
/// is its own case because the caller may want to skip such bundles
/// instead of failing the whole load.
enum DeviceChromeParseError: Error, Equatable {
    case malformedJSON
    case missingIdentifier
}

