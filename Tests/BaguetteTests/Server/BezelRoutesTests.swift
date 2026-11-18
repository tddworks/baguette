import Testing
import Foundation
import Mockable
@testable import Baguette

/// Server-handler tests for the bezel + per-button image routes.
///
/// We test the *internal* helpers that produce the raw bytes for
/// each route (`bezelImage`, `chromeButtonImage`, `chromeJSONString`)
/// rather than the Hummingbird `Response` builders that wrap them.
/// Splitting the data-producing step from the response-building step
/// makes both halves trivially testable: the route closure becomes a
/// thin "Optional<Data> → 200 / 404" wrapper, and the helpers stay
/// pure functions over `Simulators` + `Chromes` that are easy to
/// drive with mocks.
@Suite("Server bezel + chrome-button routes")
struct BezelRoutesTests {

    // MARK: - bezel image

    @Test func `should serve the bezel with its buttons merged in by default`() throws {
        let (sim, chromes) = Self.fixture()
        let bytes = Server.bezelImage(
            udid: "UDID-1",
            simulators: Self.simulators(with: sim),
            chromes: chromes,
            withButtons: true
        )
        #expect(bytes == Data("MERGED-PNG".utf8))
    }

    @Test func `should serve the bare bezel when buttons is false`() throws {
        let (sim, chromes) = Self.fixture()
        let bytes = Server.bezelImage(
            udid: "UDID-1",
            simulators: Self.simulators(with: sim),
            chromes: chromes,
            withButtons: false
        )
        #expect(bytes == Data("BARE-PNG".utf8))
    }

    // MARK: - explicit panel

    /// With `?panel=` the route serves that panel's chrome regardless of
    /// the hinge — the definition named it, and the URL must stay
    /// stable for the browser cache to be right.
    @Test func `should serve the named panel's bezel without consulting the hinge`() throws {
        let (sim, chromes) = Self.fixture()
        let unfolded = DeviceChromeAssets(
            chrome: DeviceChrome(
                identifier: "phone14",
                screenInsets: Insets(top: 0, left: 0, bottom: 0, right: 0),
                outerCornerRadius: 0, buttons: [], compositeImageName: "X"),
            composite: ChromeImage(data: Data("UNFOLDED-PNG".utf8), size: Size(width: 1, height: 1)))
        given(chromes as! MockChromes).assets(forDeviceName: .any, panel: .value(.secondary))
            .willReturn(unfolded)
        let bytes = Server.bezelImage(
            udid: "UDID-1", simulators: Self.simulators(with: sim),
            chromes: chromes, withButtons: true, panel: .secondary)
        #expect(bytes == Data("UNFOLDED-PNG".utf8))
        verify(sim as! MockSimulator).hinge().called(0)
    }

    @Test func `should accept only primary and secondary as the panel query`() {
        #expect(Server.panelQuery("secondary") == .secondary)
        #expect(Server.panelQuery("primary") == .primary)
        #expect(Server.panelQuery(nil) == nil)
        #expect(Server.panelQuery("inner") == nil)
    }

    // MARK: - screen mask

    /// The lit panel's framebuffer mask, as the page's CSS mask.
    @Test func `should serve the lit panel's rasterized screen mask`() throws {
        let (sim, chromes) = Self.fixture(screenMask: ChromeImage(
            data: Data("MASK-PNG".utf8), size: Size(width: 466, height: 678)))
        let bytes = Server.screenMaskImage(
            udid: "UDID-1", simulators: Self.simulators(with: sim), chromes: chromes)
        #expect(bytes == Data("MASK-PNG".utf8))
    }

    @Test func `should serve a borrowed bezel's screen mask by the chrome's name`() throws {
        let (_, chromes) = Self.fixture(screenMask: ChromeImage(
            data: Data("MASK-PNG".utf8), size: Size(width: 466, height: 678)))
        #expect(Server.borrowedScreenMask(named: "iPhone 17 Pro", chromes: chromes) == Data("MASK-PNG".utf8))
    }

    @Test func `should frame a physical device in its own bezel when one is installed under its model`() {
        let (_, chromes) = Self.fixture()
        #expect(Server.bezelName(picked: nil, model: "iPhone 17 Pro", chromes: chromes) == "iPhone 17 Pro")
    }

    @Test func `should frame a physical device in the bezel the user picked over its own`() {
        let (_, chromes) = Self.fixture()
        #expect(Server.bezelName(picked: "iPhone Air", model: "iPhone 17 Pro", chromes: chromes) == "iPhone Air")
    }

    @Test func `should ask for a bezel when the device's model has none installed`() {
        let chromes = MockChromes()
        given(chromes).assets(forDeviceName: .any).willReturn(nil)
        #expect(Server.bezelName(picked: nil, model: "iPhone17,2", chromes: chromes) == nil)
        #expect(Server.bezelName(picked: "", model: "iPhone17,2", chromes: chromes) == nil)
    }

    @Test func `should serve no borrowed screen mask when the chrome carries none`() throws {
        let (_, chromes) = Self.fixture()
        #expect(Server.borrowedScreenMask(named: "iPhone 17 Pro", chromes: chromes) == nil)
    }

    @Test func `should serve no screen mask when the chrome carries none`() throws {
        let (sim, chromes) = Self.fixture()
        #expect(Server.screenMaskImage(
            udid: "UDID-1", simulators: Self.simulators(with: sim), chromes: chromes) == nil)
    }

    @Test func `should rotate the simulator to a valid orientation`() {
        let host = MockSimulators()
        let sim = MockSimulator()
        let orientation = MockOrientation()
        given(host).find(udid: .value("U")).willReturn(sim)
        given(sim).orientation().willReturn(orientation)
        given(orientation).set(.value(.landscapeRight)).willReturn(.delivered)

        #expect(Server.applyOrientation(udid: "U", value: "landscape-right", simulators: host) == .ok)
        verify(orientation).set(.value(.landscapeRight)).called(1)
    }

    @Test func `should report an invalid value for an unrecognised orientation spelling`() {
        let host = MockSimulators()
        #expect(Server.applyOrientation(udid: "U", value: "sideways", simulators: host) == .invalidValue)
    }

    @Test func `should report an unknown device when rotating a simulator that can't be found`() {
        let host = MockSimulators()
        given(host).find(udid: .value("ghost")).willReturn(nil)
        #expect(Server.applyOrientation(udid: "ghost", value: "portrait", simulators: host) == .unknownDevice)
    }

    @Test func `should report an unknown device when rotating with an empty udid`() {
        let host = MockSimulators()
        #expect(Server.applyOrientation(udid: "", value: "portrait", simulators: host) == .unknownDevice)
    }

    @Test func `should report a failed dispatch when the device rejects the orientation change`() {
        let host = MockSimulators()
        let sim = MockSimulator()
        let orientation = MockOrientation()
        given(host).find(udid: .value("U")).willReturn(sim)
        given(sim).orientation().willReturn(orientation)
        given(orientation).set(.any).willReturn(.rejected)

        #expect(Server.applyOrientation(udid: "U", value: "portrait", simulators: host) == .dispatchFailed)
    }

    @Test func `should report the rotation unconfirmed when the helper times out`() {
        let host = MockSimulators()
        let sim = MockSimulator()
        let orientation = MockOrientation()
        given(host).find(udid: .value("U")).willReturn(sim)
        given(sim).orientation().willReturn(orientation)
        given(orientation).set(.any).willReturn(.unconfirmed)

        #expect(Server.applyOrientation(udid: "U", value: "portrait", simulators: host) == .unconfirmed)
    }

    @Test func `should shake the simulator`() async {
        let host = MockSimulators()
        let sim = MockSimulator()
        let shake = MockShake()
        given(host).find(udid: .value("U")).willReturn(sim)
        given(sim).shake().willReturn(shake)
        given(shake).shake().willReturn()

        #expect(await Server.applyShake(udid: "U", simulators: host) == .ok)
        verify(shake).shake().called(1)
    }

    @Test func `should report an unknown device when shaking a simulator that can't be found`() async {
        let host = MockSimulators()
        given(host).find(udid: .value("ghost")).willReturn(nil)
        #expect(await Server.applyShake(udid: "ghost", simulators: host) == .unknownDevice)
    }

    @Test func `should report an unknown device when shaking with an empty udid`() async {
        let host = MockSimulators()
        #expect(await Server.applyShake(udid: "", simulators: host) == .unknownDevice)
    }

    @Test func `should report a failed dispatch when the shake fails`() async {
        let host = MockSimulators()
        let sim = MockSimulator()
        let shake = MockShake()
        given(host).find(udid: .value("U")).willReturn(sim)
        given(sim).shake().willReturn(shake)
        given(shake).shake().willThrow(ShakeError.simctlFailed(status: 1))

        #expect(await Server.applyShake(udid: "U", simulators: host) == .dispatchFailed)
    }

    @Test func `should serve no bezel for an unknown udid`() {
        let chromes = MockChromes()
        given(chromes).panels(forDeviceName: .any).willReturn([.primary])
        let sims = MockSimulators()
        given(sims).find(udid: .value("ghost")).willReturn(nil)

        let bytes = Server.bezelImage(
            udid: "ghost",
            simulators: sims,
            chromes: chromes,
            withButtons: true
        )
        #expect(bytes == nil)
    }

    // MARK: - chrome-button image

    @Test func `should serve a chrome button's png for a known button name`() throws {
        let (sim, chromes) = Self.fixture()
        let bytes = Server.chromeButtonImage(
            udid: "UDID-1",
            buttonFile: "power.png",
            simulators: Self.simulators(with: sim),
            chromes: chromes
        )
        #expect(bytes == Data("POWER-PNG".utf8))
    }

    @Test func `should serve no image for a name no chrome button advertises`() {
        let (sim, chromes) = Self.fixture()
        let bytes = Server.chromeButtonImage(
            udid: "UDID-1",
            buttonFile: "siri.png",
            simulators: Self.simulators(with: sim),
            chromes: chromes
        )
        #expect(bytes == nil)
    }

    @Test func `should serve a chrome button's png when the extension is missing`() throws {
        // The URL parser yields the raw last path segment. If the
        // front end forgets the extension the handler should still
        // resolve the button name — keeps the API forgiving.
        let (sim, chromes) = Self.fixture()
        let bytes = Server.chromeButtonImage(
            udid: "UDID-1",
            buttonFile: "power",
            simulators: Self.simulators(with: sim),
            chromes: chromes
        )
        #expect(bytes == Data("POWER-PNG".utf8))
    }

    // MARK: - chrome.json carries imageUrl

    // MARK: - definition.json (SDK bootstrap)

    @Test func `should serve no device definition for an unknown udid`() {
        let sims = MockSimulators()
        given(sims).find(udid: .value("ghost")).willReturn(nil)
        let chromes = MockChromes()
        given(chromes).panels(forDeviceName: .any).willReturn([.primary])
        #expect(Server.definitionJSONString(
            udid: "ghost", simulators: sims, chromes: chromes
        ) == nil)
    }

    @Test func `should describe the device's identity, screen and buttons for the SDK bootstrap`() throws {
        let (sim, chromes) = Self.fixture()
        let json = try #require(Server.definitionJSONString(
            udid: "UDID-1", simulators: Self.simulators(with: sim), chromes: chromes
        ))
        let parsed = try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )

        let identity = try #require(parsed["identity"] as? [String: Any])
        #expect(identity["udid"]  as? String == "UDID-1")
        #expect(identity["name"]  as? String == "iPhone 17 Pro")
        #expect(identity["model"] as? String == "iPhone 17 Pro")

        let screen = try #require(parsed["screen"] as? [String: Any])
        let bezel  = try #require(screen["bezelImage"] as? [String: Any])
        #expect(bezel["rest"] as? String == "/simulators/UDID-1/bezel.png?panel=primary")
        #expect(bezel["bare"] as? String == "/simulators/UDID-1/bezel.png?buttons=false&panel=primary")

        let buttons = try #require(parsed["buttons"] as? [[String: Any]])
        #expect(buttons.count == 1)
        let power = buttons[0]
        #expect(power["id"] as? String == "power")
        let envelope = try #require(power["envelope"] as? [String: String])
        #expect(envelope == ["type": "button", "button": "power"])
        let images = try #require(power["images"] as? [String: String])
        #expect(images["rest"] == "/simulators/UDID-1/chrome-button/power.png?panel=primary")
    }

    @Test func `should give every chrome button an image URL under the device's own path`() throws {
        let (sim, chromes) = Self.fixture()
        let json = try #require(Server.chromeJSONString(
            udid: "UDID-1",
            simulators: Self.simulators(with: sim),
            chromes: chromes
        ))

        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let buttons = try #require(parsed?["buttons"] as? [[String: Any]])
        let urls = buttons.compactMap { $0["imageUrl"] as? String }
        // Every button advertises a fetchable URL pointing at the new
        // /chrome-button/<name>.png route, scoped to this udid.
        #expect(!urls.isEmpty)
        #expect(urls.allSatisfy { $0.hasPrefix("/simulators/UDID-1/chrome-button/") })
        #expect(urls.allSatisfy { $0.hasSuffix(".png") })
    }
}

// MARK: - fixtures

private extension BezelRoutesTests {

    /// One-shot fixture: a booted simulator whose chrome carries one
    /// button (`power`) plus distinct merged + bare composites
    /// so byte equality alone proves which path was taken.
    static func fixture(screenMask: ChromeImage? = nil) -> (any Simulator, any Chromes) {
        let chrome = DeviceChrome(
            identifier: "phone11",
            screenInsets: Insets(top: 0, left: 0, bottom: 0, right: 0),
            outerCornerRadius: 0,
            buttons: [
                ChromeButton(
                    name: "power",
                    imageName: "PWR",
                    anchor: .right, align: .leading,
                    offset: Point(x: 0, y: 100)
                ),
            ],
            compositeImageName: "PhoneComposite"
        )
        let assets = DeviceChromeAssets(
            chrome: chrome,
            composite: ChromeImage(
                data: Data("MERGED-PNG".utf8),
                size: Size(width: 110, height: 200)
            ),
            bareComposite: ChromeImage(
                data: Data("BARE-PNG".utf8),
                size: Size(width: 100, height: 200)
            ),
            buttonImages: [
                "power": ChromeImage(
                    data: Data("POWER-PNG".utf8),
                    size: Size(width: 10, height: 30)
                ),
            ],
            screenMask: screenMask
        )

        let chromes = MockChromes()

        given(chromes).panels(forDeviceName: .any).willReturn([.primary])
        given(chromes).assets(forDeviceName: .any).willReturn(assets)

        let sim = MockSimulator()
        given(sim).udid.willReturn("UDID-1")
        given(sim).name.willReturn("iPhone 17 Pro")
        given(sim).deviceTypeName.willReturn("iPhone 17 Pro")
        return (sim, chromes)
    }

    static func simulators(with sim: any Simulator) -> any Simulators {
        let sims = MockSimulators()
        given(sims).find(udid: .value(sim.udid)).willReturn(sim)
        return sims
    }
}
