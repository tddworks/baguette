import Testing
import Foundation
@testable import Baguette

@Suite("DeviceChrome")
struct DeviceChromeTests {

    // MARK: - parsing

    @Test func `parsing strips the chromeIdentifier prefix`() throws {
        let chrome = try DeviceChrome.parsing(json: Self.fixturePhone11)
        #expect(chrome.identifier == "phone11")
    }

    @Test func `parsing reads sizing into screenInsets`() throws {
        let chrome = try DeviceChrome.parsing(json: Self.fixturePhone11)
        #expect(chrome.screenInsets == Insets(top: 18, left: 18, bottom: 18, right: 18))
    }

    @Test func `parsing reads simpleOutsideBorder cornerRadiusX as outerCornerRadius`() throws {
        let chrome = try DeviceChrome.parsing(json: Self.fixturePhone11)
        #expect(chrome.outerCornerRadius == 80)
    }

    @Test func `parsing reads images_composite as compositeImageName`() throws {
        let chrome = try DeviceChrome.parsing(json: Self.fixturePhone11)
        #expect(chrome.compositeImageName == "PhoneComposite")
    }

    @Test func `compositeImageName is nil when chrome relies on 9-slice only`() throws {
        let chrome = try DeviceChrome.parsing(json: Self.fixtureNoComposite)
        #expect(chrome.compositeImageName == nil)
    }

    @Test func `parsing reads images slice piece names`() throws {
        // phone11 ships both `composite` and the 9-slice names; the
        // slice block stays populated regardless of whether a baked
        // composite exists, so 9-slice is always available as a fallback.
        let chrome = try DeviceChrome.parsing(json: Self.fixturePhone11)
        let slice = try #require(chrome.slice)
        #expect(slice == DeviceChromeSlice(
            topLeft: "Phone TL", top: "Phone Top", topRight: "Phone TR",
            right: "Phone Right",
            bottomRight: "Phone BR", bottom: "Phone Base", bottomLeft: "Phone BL",
            left: "Phone Left",
            screen: "Screen"
        ))
    }

    @Test func `slice is populated for 9-slice-only bundles`() throws {
        let chrome = try DeviceChrome.parsing(json: Self.fixtureSliceOnly)
        #expect(chrome.compositeImageName == nil)
        #expect(chrome.slice?.topLeft == "iPad TL")
        #expect(chrome.slice?.screen == "Screen")
    }

    @Test func `slice is nil when any of the 9 piece names is missing`() throws {
        // Drop just one key (`top`) to verify we treat the slice as
        // all-or-nothing — partial coverage isn't useful.
        let chrome = try DeviceChrome.parsing(json: Self.fixturePartialSlice)
        #expect(chrome.slice == nil)
    }

    @Test func `parsing collects buttons preserving order`() throws {
        let chrome = try DeviceChrome.parsing(json: Self.fixturePhone11)
        #expect(chrome.buttons.map(\.name) == ["action", "volume-up", "power"])
    }

    @Test func `button parses anchor align imageName and both offsets`() throws {
        // chrome.json carries TWO offsets per input — `normal` (at-rest)
        // and `rollover` (hovered, popped out a few pixels). The
        // actionable-bezel UI animates between them, so both must be
        // retained on the parsed value (not collapsed to a single
        // Point as the older "prefer rollover" parser did).
        let chrome = try DeviceChrome.parsing(json: Self.fixturePhone11)
        let action = chrome.buttons.first { $0.name == "action" }!

        #expect(action.imageName == "Mute BTN")
        #expect(action.anchor == .left)
        #expect(action.align == .leading)
        #expect(action.normalOffset   == Point(x: 8, y: 160))
        #expect(action.rolloverOffset == Point(x: 3, y: 160))
    }

    @Test func `button falls back to identical offsets when only one variant given`() throws {
        // power in the fixture supplies only `normal` (no rollover key).
        // Parser should populate both `normalOffset` and
        // `rolloverOffset` from whichever variant is present so
        // downstream animation code never has to special-case nil.
        let chrome = try DeviceChrome.parsing(json: Self.fixturePhone11)
        let power = chrome.buttons.first { $0.name == "power" }!
        #expect(power.normalOffset   == Point(x: 5, y: 200))
        #expect(power.rolloverOffset == Point(x: 5, y: 200))
        #expect(power.anchor == .right)
    }

    @Test func `chrome JSON exposes both normal and rollover offsets per button`() throws {
        let chrome = try DeviceChrome.parsing(json: Self.fixturePhone11)
        let assets = DeviceChromeAssets(
            chrome: chrome,
            composite: ChromeImage(data: Data(), size: Size(width: 100, height: 200))
        )
        let parsed = try JSONSerialization.jsonObject(
            with: Data(assets.layoutJSON().utf8)
        ) as? [String: Any]
        let buttons = try #require(parsed?["buttons"] as? [[String: Any]])
        let action = try #require(buttons.first { ($0["name"] as? String) == "action" })

        let normal = try #require(action["normalOffset"] as? [String: Any])
        let rollover = try #require(action["rolloverOffset"] as? [String: Any])
        #expect(normal["x"] as? Double == 8)
        #expect(normal["y"] as? Double == 160)
        #expect(rollover["x"] as? Double == 3)
        #expect(rollover["y"] as? Double == 160)
    }

    @Test func `button parses onTop with default false`() throws {
        // watch4-shaped fixture: digital-crown is `onTop: false` (baked
        // into the composite) and the orange action button is
        // `onTop: true` (must overlay). Bare entries with no `onTop`
        // key default to false to match the iPhone case.
        let chrome = try DeviceChrome.parsing(json: Self.fixtureWatchOnTop)
        let crown = chrome.buttons.first { $0.name == "digital-crown" }!
        let action = chrome.buttons.first { $0.name == "action" }!
        let bare = chrome.buttons.first { $0.name == "bare" }!
        #expect(crown.onTop == false)
        #expect(action.onTop == true)
        #expect(bare.onTop == false)
    }

    @Test func `parsing throws on missing identifier`() {
        let bad = Data(#"{"images":{},"paths":{},"inputs":[]}"#.utf8)
        #expect(throws: DeviceChromeParseError.missingIdentifier) {
            _ = try DeviceChrome.parsing(json: bad)
        }
    }

    @Test func `parsing throws on malformed JSON`() {
        let bad = Data("not-json".utf8)
        #expect(throws: DeviceChromeParseError.self) {
            _ = try DeviceChrome.parsing(json: bad)
        }
    }

    // Top-level array is valid JSON but not the dict shape the parser
    // requires — must throw `malformedJSON` rather than crash on the cast.
    @Test func `parsing throws malformedJSON when payload is not a dict`() {
        let bad = Data("[]".utf8)
        #expect(throws: DeviceChromeParseError.malformedJSON) {
            _ = try DeviceChrome.parsing(json: bad)
        }
    }

    // Bundles missing every optional section ("images", "paths", "inputs")
    // must still parse — they fall through every `?? [:]` / `?? []` branch
    // and produce a chrome with zeroed insets, zero radius, and no buttons.
    @Test func `parsing tolerates missing images, paths and inputs`() throws {
        let bare = Data(#"{"identifier":"phoneN"}"#.utf8)
        let chrome = try DeviceChrome.parsing(json: bare)
        #expect(chrome.identifier == "phoneN")
        #expect(chrome.screenInsets == Insets(top: 0, left: 0, bottom: 0, right: 0))
        #expect(chrome.outerCornerRadius == 0)
        #expect(chrome.buttons.isEmpty)
        #expect(chrome.compositeImageName == nil)
    }

    @Test func `button defaults anchor to left and align to leading when absent`() throws {
        let json = Data(#"""
        {
          "identifier": "phoneN",
          "inputs": [
            { "name": "naked", "image": "X" }
          ]
        }
        """#.utf8)
        let chrome = try DeviceChrome.parsing(json: json)
        let naked = try #require(chrome.buttons.first)
        #expect(naked.anchor == .left)
        #expect(naked.align == .leading)
        // Also exercises the `?? [:]` fallback for the missing offsets dict.
        #expect(naked.offset == Point(x: 0, y: 0))
    }

    @Test func `button skips entries missing required name or image fields`() throws {
        let json = Data(#"""
        {
          "identifier": "phoneN",
          "inputs": [
            { "name": "no-image" },
            { "image": "no-name" }
          ]
        }
        """#.utf8)
        let chrome = try DeviceChrome.parsing(json: json)
        #expect(chrome.buttons.isEmpty)
    }

    // MARK: - rich domain semantics

    @Test func `bezelWidth is the larger of left and top inset`() {
        let chrome = Self.makeChrome(insets: Insets(top: 12, left: 18, bottom: 12, right: 18))
        #expect(chrome.bezelWidth == 18)
    }

    @Test func `innerCornerRadius subtracts bezelWidth from outerCornerRadius`() {
        let chrome = Self.makeChrome(
            outerRadius: 80,
            insets: Insets(top: 18, left: 18, bottom: 18, right: 18)
        )
        #expect(chrome.innerCornerRadius == 62)
    }

    @Test func `innerCornerRadius clamps to zero when bezel exceeds outer radius`() {
        let chrome = Self.makeChrome(
            outerRadius: 5,
            insets: Insets(top: 18, left: 18, bottom: 18, right: 18)
        )
        #expect(chrome.innerCornerRadius == 0)
    }

    @Test func `screenRect positions the screen inside a composite size`() {
        let chrome = Self.makeChrome(insets: Insets(top: 18, left: 18, bottom: 18, right: 18))
        let rect = chrome.screenRect(in: Size(width: 393, height: 852))

        #expect(rect.origin == Point(x: 18, y: 18))
        #expect(rect.size == Size(width: 357, height: 816))
    }

    // MARK: - presentation

    @Test func `layoutJSON matches the HTTP contract`() throws {
        let chrome = Self.makeChrome(
            identifier: "phone11",
            outerRadius: 80,
            insets: Insets(top: 18, left: 18, bottom: 18, right: 18),
            buttons: [
                ChromeButton(
                    name: "action", imageName: "Mute BTN",
                    anchor: .left, align: .leading,
                    offset: Point(x: 3, y: 160)
                )
            ]
        )

        let json = chrome.layoutJSON(compositeSize: Size(width: 393, height: 852))
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]

        #expect(parsed?["identifier"] as? String == "phone11")
        #expect(parsed?["innerCornerRadius"] as? Double == 62)
        let screen = parsed?["screen"] as? [String: Any]
        #expect(screen?["x"] as? Double == 18)
        #expect(screen?["width"] as? Double == 357)
        let composite = parsed?["composite"] as? [String: Any]
        #expect(composite?["width"] as? Double == 393)
        let buttons = parsed?["buttons"] as? [[String: Any]]
        #expect(buttons?.count == 1)
        #expect(buttons?.first?["anchor"] as? String == "left")
    }

    @Test func `assets layoutJSON shifts screen by buttonMargins but keeps innerCornerRadius`() throws {
        // The merged bezel.png is 30 px wider than the original
        // composite (button overshoot baked into the canvas). The
        // asset's layoutJSON must:
        //   - report the merged composite size
        //   - shift screen.x by the left margin so it lands on the
        //     real screen cutout in the merged image
        //   - keep innerCornerRadius at the parsed chrome value
        //     (no recomputation off the inflated geometry)
        let chrome = Self.makeChrome(
            identifier: "phone11",
            outerRadius: 80,
            insets: Insets(top: 18, left: 18, bottom: 18, right: 18)
        )
        let assets = DeviceChromeAssets(
            chrome: chrome,
            composite: ChromeImage(
                data: Data(),
                size: Size(width: 466, height: 908)
            ),
            buttonMargins: Insets(top: 0, left: 13, bottom: 0, right: 17)
        )

        let parsed = try JSONSerialization.jsonObject(
            with: Data(assets.layoutJSON().utf8)
        ) as? [String: Any]

        #expect(parsed?["innerCornerRadius"] as? Double == 62)
        let composite = parsed?["composite"] as? [String: Any]
        #expect(composite?["width"] as? Double == 466)
        #expect(composite?["height"] as? Double == 908)
        let screen = parsed?["screen"] as? [String: Any]
        // screen.x = parsed inset (18) + leftMargin (13) = 31; the
        // screen rect's width/height come from the *original*
        // composite (insets carved out of 466-30 wide).
        #expect(screen?["x"] as? Double == 31)
        #expect(screen?["y"] as? Double == 18)
        #expect(screen?["width"] as? Double == 400)
        #expect(screen?["height"] as? Double == 872)
    }

    @Test func `assets layoutJSON with default zero margins keeps the chrome projection geometry`() throws {
        // No buttons → zero margins → composite size, screen rect,
        // and corner radii match the chrome's own projection. The
        // asset version always carries the additive `buttonMargins`
        // block (all zeros here) so today's consumers see a
        // superset, not a strictly identical document. We compare on
        // the geometry fields that *must* line up, not byte-for-byte.
        let chrome = Self.makeChrome()
        let assets = DeviceChromeAssets(
            chrome: chrome,
            composite: ChromeImage(data: Data(), size: Size(width: 393, height: 852))
        )

        let chromeJSON = chrome.layoutJSON(compositeSize: Size(width: 393, height: 852))
        let chromeParsed = try JSONSerialization.jsonObject(
            with: Data(chromeJSON.utf8)
        ) as? [String: Any]
        let assetParsed = try JSONSerialization.jsonObject(
            with: Data(assets.layoutJSON().utf8)
        ) as? [String: Any]

        for key in ["composite", "screen", "innerCornerRadius",
                    "outerCornerRadius", "identifier"] {
            #expect(
                "\(assetParsed?[key] ?? "nil")" == "\(chromeParsed?[key] ?? "nil")",
                "asset/chrome JSON disagree on \(key)"
            )
        }
        let m = try #require(assetParsed?["buttonMargins"] as? [String: Any])
        #expect(m.values.allSatisfy { ($0 as? Double) == 0 })
    }

    // MARK: - imageUrl injection (actionable bezel)

    @Test func `assets layoutJSON omits imageUrl when no prefix is given`() throws {
        // Back-compat: today's callers pass nothing and get exactly the
        // shape they get today. No imageUrl field on any button entry.
        let chrome = Self.makeChromeWithButtons()
        let assets = DeviceChromeAssets(
            chrome: chrome,
            composite: ChromeImage(data: Data(), size: Size(width: 100, height: 200))
        )

        let parsed = try JSONSerialization.jsonObject(
            with: Data(assets.layoutJSON().utf8)
        ) as? [String: Any]
        let buttons = try #require(parsed?["buttons"] as? [[String: Any]])
        #expect(buttons.allSatisfy { $0["imageUrl"] == nil })
    }

    @Test func `assets layoutJSON exposes buttonMargins so the front end can derive bare composite size`() throws {
        // The actionable-bezel front end fetches `bezel.png?buttons=false`
        // (smaller than the merged composite). To position the screen
        // rect + per-button images against the *bare* bezel it needs
        // to know how much margin the merge added — exposing the four
        // overshoot values in chrome.json keeps the math client-side
        // without a second metadata fetch.
        let chrome = Self.makeChrome()
        let assets = DeviceChromeAssets(
            chrome: chrome,
            composite: ChromeImage(data: Data(), size: Size(width: 466, height: 908)),
            buttonMargins: Insets(top: 0, left: 13, bottom: 0, right: 17)
        )

        let parsed = try JSONSerialization.jsonObject(
            with: Data(assets.layoutJSON().utf8)
        ) as? [String: Any]
        let m = try #require(parsed?["buttonMargins"] as? [String: Any])
        #expect(m["top"]    as? Double == 0)
        #expect(m["left"]   as? Double == 13)
        #expect(m["bottom"] as? Double == 0)
        #expect(m["right"]  as? Double == 17)
    }

    @Test func `assets layoutJSON adds imageUrl per button when prefix is given`() throws {
        // The server passes "/simulators/<udid>/chrome-button/" so each
        // button entry advertises a fetchable URL for its rasterized
        // image. The domain stays URL-agnostic — the prefix is the
        // server's responsibility, the suffix is `<name>.png`.
        let chrome = Self.makeChromeWithButtons()
        let assets = DeviceChromeAssets(
            chrome: chrome,
            composite: ChromeImage(data: Data(), size: Size(width: 100, height: 200))
        )

        let parsed = try JSONSerialization.jsonObject(
            with: Data(assets.layoutJSON(
                buttonImageURLPrefix: "/simulators/UDID-XYZ/chrome-button/"
            ).utf8)
        ) as? [String: Any]
        let buttons = try #require(parsed?["buttons"] as? [[String: Any]])
        let urls = buttons.compactMap { $0["imageUrl"] as? String }
        #expect(urls == [
            "/simulators/UDID-XYZ/chrome-button/powerButton.png",
            "/simulators/UDID-XYZ/chrome-button/volumeUp.png",
        ])
    }
}

// MARK: - fixtures

private extension DeviceChromeTests {

    static func makeChrome(
        identifier: String = "phone11",
        outerRadius: Double = 80,
        insets: Insets = Insets(top: 18, left: 18, bottom: 18, right: 18),
        buttons: [ChromeButton] = [],
        compositeImageName: String? = "PhoneComposite"
    ) -> DeviceChrome {
        DeviceChrome(
            identifier: identifier,
            screenInsets: insets,
            outerCornerRadius: outerRadius,
            buttons: buttons,
            compositeImageName: compositeImageName
        )
    }

    /// Two-button fixture — names mirror what real DeviceKit chromes
    /// emit (`powerButton`, `volumeUp`). Used for `imageUrl` injection
    /// tests where the values matter, not the geometry.
    static func makeChromeWithButtons() -> DeviceChrome {
        makeChrome(buttons: [
            ChromeButton(
                name: "powerButton",
                imageName: "PWR",
                anchor: .right,
                align: .leading,
                offset: Point(x: 0, y: 200)
            ),
            ChromeButton(
                name: "volumeUp",
                imageName: "VOL+",
                anchor: .left,
                align: .leading,
                offset: Point(x: 0, y: 100)
            ),
        ])
    }

    /// Same shape as `fixturePhone11` but with `images.composite` removed
    /// AND only one slice piece — exercises the path where neither a
    /// baked composite nor a complete 9-slice are usable.
    static let fixtureNoComposite: Data = Data(#"""
    {
      "identifier": "com.apple.dt.devicekit.chrome.phoneN",
      "images": {
        "topLeft": "Phone TL",
        "sizing": { "leftWidth": 18, "rightWidth": 18, "topHeight": 18, "bottomHeight": 18 }
      },
      "paths": { "simpleOutsideBorder": { "cornerRadiusX": 80, "cornerRadiusY": 80 } },
      "inputs": []
    }
    """#.utf8)

    /// Real-shape iPad / phone13 bundle — no `composite` key, but every
    /// 9-slice piece present. Mirrors what `tablet*.devicechrome` ship.
    static let fixtureSliceOnly: Data = Data(#"""
    {
      "identifier": "com.apple.dt.devicekit.chrome.tablet5",
      "images": {
        "topLeft": "iPad TL",
        "top": "iPadTop",
        "topRight": "iPad TR",
        "right": "iPadRight",
        "bottomRight": "iPad BR",
        "bottom": "iPadBase",
        "bottomLeft": "iPad BL",
        "left": "iPadLeft",
        "screen": "Screen",
        "sizing": { "leftWidth": 46, "rightWidth": 46, "topHeight": 46, "bottomHeight": 46 }
      },
      "paths": { "simpleOutsideBorder": { "cornerRadiusX": 75 } },
      "inputs": []
    }
    """#.utf8)

    /// 8 of 9 slice keys (`top` removed). Slice should resolve to nil
    /// — partial coverage isn't enough to compose a bezel.
    static let fixturePartialSlice: Data = Data(#"""
    {
      "identifier": "com.apple.dt.devicekit.chrome.partial",
      "images": {
        "topLeft": "TL",
        "topRight": "TR",
        "right": "R",
        "bottomRight": "BR",
        "bottom": "B",
        "bottomLeft": "BL",
        "left": "L",
        "screen": "S",
        "sizing": { "leftWidth": 0, "rightWidth": 0, "topHeight": 0, "bottomHeight": 0 }
      },
      "paths": { "simpleOutsideBorder": { "cornerRadiusX": 0 } },
      "inputs": []
    }
    """#.utf8)

    /// Watch-shaped inputs covering the `onTop` field. `digital-crown`
    /// is `false`, `action` is `true`, `bare` omits the key entirely
    /// to exercise the default.
    static let fixtureWatchOnTop: Data = Data(#"""
    {
      "identifier": "com.apple.dt.devicekit.chrome.watch4",
      "inputs": [
        { "name": "digital-crown", "image": "DigitalCrown", "anchor": "right",
          "onTop": false,
          "offsets": { "normal": { "x": -23, "y": 81 } } },
        { "name": "action", "image": "StingButton", "anchor": "left",
          "onTop": true,
          "offsets": { "normal": { "x": 20, "y": 138 } } },
        { "name": "bare", "image": "BTN", "anchor": "left" }
      ]
    }
    """#.utf8)

    /// Minimal but realistic chrome.json — same shape as phone11.devicechrome.
    /// Three buttons exercise: (a) rollover offset wins (action), (b) right
    /// anchor with only normal offsets (power), (c) ordering preservation.
    static let fixturePhone11: Data = Data(#"""
    {
      "identifier": "com.apple.dt.devicekit.chrome.phone11",
      "images": {
        "topLeft": "Phone TL",
        "top": "Phone Top",
        "topRight": "Phone TR",
        "right": "Phone Right",
        "bottomRight": "Phone BR",
        "bottom": "Phone Base",
        "bottomLeft": "Phone BL",
        "left": "Phone Left",
        "composite": "PhoneComposite",
        "screen": "Screen",
        "sizing": {
          "leftWidth": 18,
          "rightWidth": 18,
          "topHeight": 18,
          "bottomHeight": 18
        }
      },
      "paths": {
        "simpleOutsideBorder": {
          "cornerRadiusX": 80,
          "cornerRadiusY": 80
        }
      },
      "inputs": [
        {
          "name": "action",
          "image": "Mute BTN",
          "anchor": "left",
          "align": "leading",
          "offsets": {
            "normal": { "x": 8, "y": 160 },
            "rollover": { "x": 3, "y": 160 }
          }
        },
        {
          "name": "volume-up",
          "image": "Vol BTN",
          "anchor": "left",
          "align": "leading",
          "offsets": {
            "rollover": { "x": 3, "y": 240 }
          }
        },
        {
          "name": "power",
          "image": "X_Power BTN",
          "anchor": "right",
          "align": "trailing",
          "offsets": {
            "normal": { "x": 5, "y": 200 }
          }
        }
      ]
    }
    """#.utf8)
}
