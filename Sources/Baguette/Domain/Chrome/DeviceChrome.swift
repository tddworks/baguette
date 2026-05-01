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
    let anchor: Anchor
    let align: Align
    let offset: Point

    var json: [String: Any] {
        [
            "name": name,
            "imageName": imageName,
            "anchor": anchor.rawValue,
            "align": align.rawValue,
            "offset": ["x": offset.x, "y": offset.y],
        ]
    }

    init(
        name: String, imageName: String,
        anchor: Anchor, align: Align,
        offset: Point
    ) {
        self.name = name
        self.imageName = imageName
        self.anchor = anchor
        self.align = align
        self.offset = offset
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

        // Prefer rollover (the "active" offset) over normal so the
        // bezel sits over the button cap that's actually drawn.
        let offsets = dict["offsets"] as? [String: Any]
        let offsetDict = (offsets?["rollover"] as? [String: Any])
            ?? (offsets?["normal"] as? [String: Any])
            ?? [:]
        self.init(
            name: name, imageName: imageName,
            anchor: anchor, align: align,
            offset: Point(
                x: coerceDouble(offsetDict["x"]),
                y: coerceDouble(offsetDict["y"])
            )
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

