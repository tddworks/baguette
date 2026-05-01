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

    @Test func `parsing collects buttons preserving order`() throws {
        let chrome = try DeviceChrome.parsing(json: Self.fixturePhone11)
        #expect(chrome.buttons.map(\.name) == ["action", "volume-up", "power"])
    }

    @Test func `button parses anchor align imageName and offset preferring rollover`() throws {
        let chrome = try DeviceChrome.parsing(json: Self.fixturePhone11)
        let action = chrome.buttons.first { $0.name == "action" }!

        #expect(action.imageName == "Mute BTN")
        #expect(action.anchor == .left)
        #expect(action.align == .leading)
        // rollover wins over normal
        #expect(action.offset == Point(x: 3, y: 160))
    }

    @Test func `button falls back to normal offset when rollover absent`() throws {
        let chrome = try DeviceChrome.parsing(json: Self.fixturePhone11)
        let power = chrome.buttons.first { $0.name == "power" }!
        // power has only "normal" offsets in the fixture
        #expect(power.offset == Point(x: 5, y: 200))
        #expect(power.anchor == .right)
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

    @Test func `assets layoutJSON with default zero margins matches the chrome projection`() throws {
        // No buttons → zero margins → asset projection lines up with
        // the existing per-chrome projection. Locks down the
        // back-compat path: chromes that don't compose buttons
        // produce identical layout JSON.
        let chrome = Self.makeChrome()
        let assets = DeviceChromeAssets(
            chrome: chrome,
            composite: ChromeImage(data: Data(), size: Size(width: 393, height: 852))
        )

        let chromeJSON = chrome.layoutJSON(compositeSize: Size(width: 393, height: 852))
        #expect(assets.layoutJSON() == chromeJSON)
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

    /// Same shape as `fixturePhone11` but with `images.composite` removed —
    /// represents a chrome bundle that ships only 9-slice pieces. We don't
    /// rasterize 9-slice today; the parser should report `nil` so callers
    /// can skip such bundles cleanly.
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
