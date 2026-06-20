import Testing
import Foundation
import Mockable
@testable import BaguetteCore

/// `SimulatorDefinition.compose` is the pure projection that the SDK
/// bootstrap endpoint (`/simulators/<udid>/definition.json`) serialises.
/// One simulator + its chrome → one value-typed description of the
/// parts the JS SDK will instantiate (`Simulator.screen`,
/// `Simulator.buttons[*]`, …). This is the one-shot-fetch factory
/// pattern from CLAUDE.md — no `@Mockable` collaborator needed.
@Suite("SimulatorDefinition.compose")
struct SimulatorDefinitionTests {

    @Test func `identity carries the simulator's udid, name, and device-type name`() {
        let def = Self.composeFixture()
        #expect(def.identity.udid == "UDID-1")
        #expect(def.identity.name == "iPhone 17 Pro")
        #expect(def.identity.model == "iPhone 17 Pro")
    }

    @Test func `screen viewport equals the bare composite size`() {
        // The SDK always overlays buttons; the bezel image served to
        // the browser is `bezel.png?buttons=false` (the bare device
        // body), so the viewport reported in the definition is the
        // *bare* size, not the merged size. When buttonMargins are
        // zero (fixture default), bare == merged and the value stays
        // at 400×800; that's also exercised by the with-margins test.
        let def = Self.composeFixture()
        #expect(def.screen.viewport == Size(width: 400, height: 800))
    }

    @Test func `screen viewport subtracts buttonMargins so it matches the bare bezel`() {
        let def = Self.composeFixtureWithMargins()
        // composite 420×820, margins {top:10, left:10, bottom:10, right:10}
        //   → bare = 400 × 800
        #expect(def.screen.viewport == Size(width: 400, height: 800))
    }

    @Test func `screen rect is in bare-bezel coordinates`() {
        let def = Self.composeFixtureWithMargins()
        // chrome insets are {top:20, left:10, bottom:20, right:10} on
        // a 400×800 bare composite → screen at (10,20) size (380, 760)
        #expect(def.screen.rect == Rect(
            origin: Point(x: 10, y: 20),
            size:   Size(width: 380, height: 760)
        ))
    }

    @Test func `screen rect is the screen cutout inside the composite`() {
        let def = Self.composeFixture()
        // composite 400×800, insets {10, 20, 10, 20}  →  screen at (10,20) size (380, 760)
        #expect(def.screen.rect == Rect(
            origin: Point(x: 10, y: 20),
            size:   Size(width: 380, height: 760)
        ))
    }

    @Test func `screen clip radius is the chrome's inner corner radius`() {
        let def = Self.composeFixture()
        // outerCornerRadius 60, bezelWidth = max(left=10, top=20) = 20  →  inner = 40
        #expect(def.screen.clipRadius == 40)
    }

    @Test func `screen bezel image URLs are scoped to the simulator's udid`() {
        let def = Self.composeFixture()
        #expect(def.screen.bezelImage.rest == "/simulators/UDID-1/bezel.png")
        #expect(def.screen.bezelImage.bare == "/simulators/UDID-1/bezel.png?buttons=false")
    }

    // MARK: - buttons

    @Test func `buttons list mirrors the chrome's input order`() {
        let def = Self.composeFixtureWithButtons()
        // Apple's chrome.json `name` is already hyphenated lowercase —
        // `"power"`, `"volume-up"`, … — so the SDK `id` and the wire
        // `button` value are the same string. Pre-cutover the JS
        // had to camelCase-to-hyphenate; Swift now owns the table.
        #expect(def.buttons.map(\.id) == ["power", "volume-up"])
    }

    @Test func `each button carries its wire envelope as the SDK will send it`() {
        let def = Self.composeFixtureWithButtons()
        // The JS SDK calls `button.press({hold: t})` which the SDK
        // serialises to `{type:"button", button:"<wire>", duration:t}`.
        // The envelope here is the type+button half — duration is
        // attached at press time, not in the definition.
        #expect(def.buttons[0].envelope == ["type": "button", "button": "power"])
        #expect(def.buttons[1].envelope == ["type": "button", "button": "volume-up"])
    }

    @Test func `button image URLs route through the per-udid chrome-button path`() {
        let def = Self.composeFixtureWithButtons()
        #expect(def.buttons[0].images.rest    == "/simulators/UDID-1/chrome-button/power.png")
        #expect(def.buttons[0].images.pressed == "/simulators/UDID-1/chrome-button/power-down.png")
        // Volume-up has no imageDown in this fixture — pressed falls
        // back to rest so the JS SDK's swap is a no-op.
        #expect(def.buttons[1].images.pressed == "/simulators/UDID-1/chrome-button/volume-up.png")
    }

    @Test func `button z-order maps the chrome's onTop flag to a domain enum`() {
        let def = Self.composeFixtureWithButtons()
        #expect(def.buttons[0].z == .below)  // iPhone power: poke through bezel slot
        #expect(def.buttons[1].z == .below)
    }

    @Test func `right-anchor button positions at the mirrored at-rest point`() {
        // power button: anchor=.right, normal=(−8, 320), rollover=(−3, 320)
        // image 10×30, bare bezel 400×800.
        // restX = 2·(−8) − (−3) = −13  →  left = (400 + (−13)) / 400 = 96.75%
        // restY = 2·320 − 320 = 320     →  top  = 320 / 800           = 40.0%
        // width  = 10 / 400 = 2.5%        height = 30 / 800            = 3.75%
        let def = Self.composeFixtureWithButtons()
        let power = def.buttons[0]
        #expect(abs(power.box.leftPct   - 96.75) < 0.001)
        #expect(abs(power.box.topPct    - 40.0)  < 0.001)
        #expect(abs(power.box.widthPct  - 2.5)   < 0.001)
        #expect(abs(power.box.heightPct - 3.75)  < 0.001)
    }

    @Test func `top-anchor button protrudes above the bare composite, like right-anchor protrudes past the right edge`() {
        // iPad Pro 13-inch (M4) data, abridged: tablet5 ships the
        // power button as anchor=.top, align=.trailing with
        // normal=(-74, 8), rollover=(-74, 3) and a 63×16 cap, on a
        // 1124×1468 bare bezel.
        //
        // Top-anchor caps must protrude UPWARD past the bare top
        // edge — analogous to right-anchor caps protruding past
        // the right rail. Mirroring the rollover-delta inward
        // mirrors what the existing right-anchor formula does:
        //   restY  = 2·8 − 3 = 13
        //   topPct = (restY − imageH) / bareH × 100
        //          = (13 − 16) / 1468 × 100 = −0.2044%   (NEGATIVE)
        //
        // For align=.trailing, offset.x is the inset from the body's
        // RIGHT edge to the cap's TRAILING (right) edge — NOT to its
        // centre. Mirrors how `.right` with align=.leading treats
        // offset.y as the inset to the cap's leading (top) edge. So
        // the cap's left edge sits at bareW + restX − imageW, putting
        // the cap to the LEFT of where a centre-anchored placement
        // would land. Compared to the real iPad Pro 13-inch (M4),
        // the centre-anchored interpretation drifted the cap ~32 px
        // (half the 63 px image width) too far right.
        let def = Self.composeFixtureWithTopButton()
        let power = def.buttons[0]
        let expectedLeftPct  = (1124.0 + (-74.0) - 63.0) / 1124.0 * 100
        let expectedTopPct   = (13.0 - 16.0) / 1468.0 * 100
        let expectedWidthPct = 63.0 / 1124.0 * 100
        let expectedHeightPct = 16.0 / 1468.0 * 100
        #expect(abs(power.box.leftPct   - expectedLeftPct)   < 0.001)
        #expect(abs(power.box.topPct    - expectedTopPct)    < 0.001)
        #expect(abs(power.box.widthPct  - expectedWidthPct)  < 0.001)
        #expect(abs(power.box.heightPct - expectedHeightPct) < 0.001)
        // Negative topPct is the load-bearing invariant — the cap
        // must sit ABOVE the bare top edge for the SDK's z=below
        // overlay scheme to leave the visible portion uncovered.
        #expect(power.box.topPct < 0)
    }

    @Test func `left-anchor button positions at the rollover point, centred horizontally`() {
        // volume-up: anchor=.left, offset=(8, 240)  (normal == rollover)
        // image 10×30, bare bezel 400×800.
        // cx = 8 / 400 = 2%   halfW = 5 / 400 = 1.25%   →  left = 0.75%
        // top = 240 / 800 = 30%
        let def = Self.composeFixtureWithButtons()
        let vol = def.buttons[1]
        #expect(abs(vol.box.leftPct - 0.75) < 0.001)
        #expect(abs(vol.box.topPct  - 30.0) < 0.001)
    }

    @Test func `button transforms drive the at-rest -> hover -> pressed animation as image-space percents`() {
        // power: normal=(−8, 320), rollover=(−3, 320), image 10×30
        // outDx = (−3 − (−8)) / 10 = 50%    outDy = 0
        // hover translates outward (+50%, 0%); pressed receded (-50%, 0%);
        // rest is the at-rest position so CSS transform is "none".
        let def = Self.composeFixtureWithButtons()
        let t = def.buttons[0].transform
        #expect(t.rest    == "none")
        #expect(t.hover   == "translate(50%, 0%)")
        #expect(t.pressed == "translate(-50%, 0%)")
    }

    @Test func `omitted buttons section yields an empty list, not nil`() {
        let def = Self.composeFixture()  // no buttons in chrome
        #expect(def.buttons == [])
    }

    // MARK: - keyboard

    @Test func `iPhone-class chrome carries a keyboard part`() {
        let def = Self.composeFixture()  // phone17 identifier
        #expect(def.keyboard != nil)
    }

    @Test func `Apple TV chrome omits the keyboard part`() {
        // tv5 / tv6 chrome identifier — Apple TV's screen isn't a
        // touch surface and software keyboard input is mediated by
        // the Siri Remote, not the device. Definition omits the
        // `keyboard` field; SDK instantiates no Keyboard part.
        let def = Self.composeAppleTVFixture()
        #expect(def.keyboard == nil)
    }

    // MARK: - fixture

    static func composeFixture() -> SimulatorDefinition {
        let sim = MockSimulator()
        given(sim).udid.willReturn("UDID-1")
        given(sim).name.willReturn("iPhone 17 Pro")
        given(sim).deviceTypeName.willReturn("iPhone 17 Pro")

        let chrome = DeviceChrome(
            identifier: "phone17",
            screenInsets: Insets(top: 20, left: 10, bottom: 20, right: 10),
            outerCornerRadius: 60,
            buttons: [],
            compositeImageName: "PhoneComposite"
        )
        let assets = DeviceChromeAssets(
            chrome: chrome,
            composite: ChromeImage(
                data: Data("MERGED".utf8),
                size: Size(width: 400, height: 800)
            )
        )

        return SimulatorDefinition.compose(
            from: sim, chrome: assets, urlPrefix: "/simulators/UDID-1"
        )
    }

    /// Apple TV-like chrome — identifier prefixed `tv` so the
    /// keyboard presence rule (which keys off the chrome family)
    /// drops the part. Used to pin Apple TV's no-keyboard semantics.
    static func composeAppleTVFixture() -> SimulatorDefinition {
        let sim = MockSimulator()
        given(sim).udid.willReturn("UDID-TV")
        given(sim).name.willReturn("Apple TV 4K")
        given(sim).deviceTypeName.willReturn("Apple TV 4K (3rd generation)")
        let chrome = DeviceChrome(
            identifier: "tv5",
            screenInsets: Insets(top: 0, left: 0, bottom: 0, right: 0),
            outerCornerRadius: 0,
            buttons: [],
            compositeImageName: "TVComposite"
        )
        let assets = DeviceChromeAssets(
            chrome: chrome,
            composite: ChromeImage(data: Data("TV".utf8), size: Size(width: 1920, height: 1080))
        )
        return SimulatorDefinition.compose(
            from: sim, chrome: assets, urlPrefix: "/simulators/UDID-TV"
        )
    }

    /// composite 420×820 with 10-px margins on every side
    ///   → bare 400×800. Same screen insets as the no-margin fixture
    /// so the resulting screen rect in bare coords is identical to
    /// what the no-margin fixture's tests expect.
    static func composeFixtureWithMargins() -> SimulatorDefinition {
        let sim = MockSimulator()
        given(sim).udid.willReturn("UDID-1")
        given(sim).name.willReturn("iPhone 17 Pro")
        given(sim).deviceTypeName.willReturn("iPhone 17 Pro")
        let chrome = DeviceChrome(
            identifier: "phone17",
            screenInsets: Insets(top: 20, left: 10, bottom: 20, right: 10),
            outerCornerRadius: 60,
            buttons: [],
            compositeImageName: "PhoneComposite"
        )
        let assets = DeviceChromeAssets(
            chrome: chrome,
            composite: ChromeImage(
                data: Data("MERGED".utf8),
                size: Size(width: 420, height: 820)
            ),
            buttonMargins: Insets(top: 10, left: 10, bottom: 10, right: 10)
        )
        return SimulatorDefinition.compose(
            from: sim, chrome: assets, urlPrefix: "/simulators/UDID-1"
        )
    }

    /// iPad-style fixture: a single top-anchor, trailing-aligned
    /// power button on a 1124×1468 bare bezel, mirroring the
    /// tablet5/iPad Pro 13-inch (M4) chrome data — 63×16 cap with
    /// normal=(-74, 8), rollover=(-74, 3), and a `top: 9` device
    /// padding so the merged canvas reserves room for the cap to
    /// poke up past the body.
    static func composeFixtureWithTopButton() -> SimulatorDefinition {
        let sim = MockSimulator()
        given(sim).udid.willReturn("UDID-IPAD")
        given(sim).name.willReturn("iPad Pro 13-inch (M4)")
        given(sim).deviceTypeName.willReturn("iPad Pro 13-inch (M4)")

        let chrome = DeviceChrome(
            identifier: "tablet5",
            screenInsets: Insets(top: 46, left: 46, bottom: 46, right: 46),
            outerCornerRadius: 81,
            buttons: [
                ChromeButton(
                    name: "power",
                    imageName: "PWR",
                    anchor: .top, align: .trailing,
                    normalOffset: Point(x: -74, y: 8),
                    rolloverOffset: Point(x: -74, y: 3),
                    onTop: false
                ),
            ],
            compositeImageName: "iPadBase"
        )
        let assets = DeviceChromeAssets(
            chrome: chrome,
            composite: ChromeImage(
                data: Data("MERGED".utf8),
                size: Size(width: 1134, height: 1477)
            ),
            buttonImages: [
                "power": ChromeImage(data: Data("PWR".utf8), size: Size(width: 63, height: 16)),
            ],
            buttonMargins: Insets(top: 9, left: 0, bottom: 0, right: 10)
        )
        return SimulatorDefinition.compose(
            from: sim, chrome: assets, urlPrefix: "/simulators/UDID-IPAD"
        )
    }

    /// Same simulator, but a chrome carrying two buttons: a power
    /// button with a pressed-state sprite, and a volume-up button
    /// without one. Exercises both `images.pressed` branches.
    static func composeFixtureWithButtons() -> SimulatorDefinition {
        let sim = MockSimulator()
        given(sim).udid.willReturn("UDID-1")
        given(sim).name.willReturn("iPhone 17 Pro")
        given(sim).deviceTypeName.willReturn("iPhone 17 Pro")

        let chrome = DeviceChrome(
            identifier: "phone17",
            screenInsets: Insets(top: 20, left: 10, bottom: 20, right: 10),
            outerCornerRadius: 60,
            buttons: [
                ChromeButton(
                    name: "power",
                    imageName: "PWR",
                    imageDownName: "PWR-down",
                    imageDownDrawMode: "replace",
                    anchor: .right, align: .leading,
                    normalOffset: Point(x: -8, y: 320),
                    rolloverOffset: Point(x: -3, y: 320),
                    onTop: false
                ),
                ChromeButton(
                    name: "volume-up",
                    imageName: "VOL",
                    anchor: .left, align: .leading,
                    offset: Point(x: 8, y: 240)
                ),
            ],
            compositeImageName: "PhoneComposite"
        )
        let assets = DeviceChromeAssets(
            chrome: chrome,
            composite: ChromeImage(
                data: Data("MERGED".utf8),
                size: Size(width: 400, height: 800)
            ),
            buttonImages: [
                "power":     ChromeImage(data: Data("PWR".utf8),
                                         size: Size(width: 10, height: 30)),
                "volume-up": ChromeImage(data: Data("VOL".utf8),
                                         size: Size(width: 10, height: 30)),
            ]
        )

        return SimulatorDefinition.compose(
            from: sim, chrome: assets, urlPrefix: "/simulators/UDID-1"
        )
    }
}
