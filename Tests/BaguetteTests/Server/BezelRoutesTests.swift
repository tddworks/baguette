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

    @Test func `bezelImage default returns the merged composite bytes`() throws {
        let (sim, chromes) = Self.fixture()
        let bytes = Server.bezelImage(
            udid: "UDID-1",
            simulators: Self.simulators(with: sim),
            chromes: chromes,
            withButtons: true
        )
        #expect(bytes == Data("MERGED-PNG".utf8))
    }

    @Test func `bezelImage with buttons false returns the bare composite bytes`() throws {
        let (sim, chromes) = Self.fixture()
        let bytes = Server.bezelImage(
            udid: "UDID-1",
            simulators: Self.simulators(with: sim),
            chromes: chromes,
            withButtons: false
        )
        #expect(bytes == Data("BARE-PNG".utf8))
    }

    @Test func `bezelImage returns nil for an unknown udid`() {
        let chromes = MockChromes()
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

    @Test func `chromeButtonImage returns the per-button png for a known name`() throws {
        let (sim, chromes) = Self.fixture()
        let bytes = Server.chromeButtonImage(
            udid: "UDID-1",
            buttonFile: "powerButton.png",
            simulators: Self.simulators(with: sim),
            chromes: chromes
        )
        #expect(bytes == Data("POWER-PNG".utf8))
    }

    @Test func `chromeButtonImage returns nil for a name no button advertises`() {
        let (sim, chromes) = Self.fixture()
        let bytes = Server.chromeButtonImage(
            udid: "UDID-1",
            buttonFile: "siri.png",
            simulators: Self.simulators(with: sim),
            chromes: chromes
        )
        #expect(bytes == nil)
    }

    @Test func `chromeButtonImage tolerates a missing png extension`() throws {
        // The URL parser yields the raw last path segment. If the
        // front end forgets the extension the handler should still
        // resolve the button name — keeps the API forgiving.
        let (sim, chromes) = Self.fixture()
        let bytes = Server.chromeButtonImage(
            udid: "UDID-1",
            buttonFile: "powerButton",
            simulators: Self.simulators(with: sim),
            chromes: chromes
        )
        #expect(bytes == Data("POWER-PNG".utf8))
    }

    // MARK: - chrome.json carries imageUrl

    @Test func `chromeJSONString includes imageUrl per button under the per-udid prefix`() throws {
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
    /// button (`powerButton`) plus distinct merged + bare composites
    /// so byte equality alone proves which path was taken.
    static func fixture() -> (Simulator, any Chromes) {
        let chrome = DeviceChrome(
            identifier: "phone11",
            screenInsets: Insets(top: 0, left: 0, bottom: 0, right: 0),
            outerCornerRadius: 0,
            buttons: [
                ChromeButton(
                    name: "powerButton",
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
                "powerButton": ChromeImage(
                    data: Data("POWER-PNG".utf8),
                    size: Size(width: 10, height: 30)
                ),
            ]
        )

        let chromes = MockChromes()
        given(chromes).assets(forDeviceName: .any).willReturn(assets)

        let sim = Simulator(
            udid: "UDID-1",
            name: "iPhone 17 Pro",
            state: .booted,
            host: MockSimulators()
        )
        return (sim, chromes)
    }

    static func simulators(with sim: Simulator) -> any Simulators {
        let sims = MockSimulators()
        given(sims).find(udid: .value(sim.udid)).willReturn(sim)
        return sims
    }
}
