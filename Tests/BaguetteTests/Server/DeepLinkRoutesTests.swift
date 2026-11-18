import Testing
import Foundation
import Mockable
@testable import Baguette

/// Handler-level coverage for the console's two routes. We drive the
/// pure dispatch helpers rather than the Hummingbird `Response`
/// wrappers, with one device's `MockApps`.
///
/// `openURL` reports *where the link went*, not just whether dispatch
/// succeeded — an https link dispatches perfectly happily and then lands
/// in Safari, so "ok" alone would be a lie the URL bar repeats to the
/// developer. `schemes` answers the completion inventory, ranked
/// server-side so the browser never has to re-implement the ordering.
@Suite("Server deep-link routes")
struct DeepLinkRoutesTests {

    private func host(
        installed: [InstalledApp] = [],
        openSucceeds: Bool = true,
        listSucceeds: Bool = true
    ) -> (any Devices, MockApps) {
        let apps = MockApps()
        let simulators = routeDevices { $0.register(.apps) { apps } }

        if openSucceeds {
            given(apps).open(.any).willReturn(())
        } else {
            given(apps).open(.any).willThrow(AppsError.openFailed(status: 1))
        }
        if listSucceeds {
            given(apps).installed().willReturn(installed)
        } else {
            given(apps).installed().willThrow(AppsError.listFailed(status: 1))
        }
        return (simulators, apps)
    }

    private static let myApp = InstalledApp(
        bundleIdentifier: "com.example.MyApp",
        name: "My App",
        schemes: ["myapp", "com.example.myapp"]
    )

    // MARK: - openurl

    @Test func `should report that a custom-scheme link reached the app`() async {
        let (simulators, apps) = host()
        let outcome = await Server.openURL(udid: "U", url: "myapp://profile", devices: simulators)

        #expect(outcome == .opened(routing: .app))
        verify(apps).open(.value(DeepLink.from("myapp://profile")!)).called(1)
    }

    @Test func `should report that an https link went to the browser`() async {
        // Dispatch succeeds; the link still lands in Safari. The URL bar
        // needs to say so, so the outcome carries the routing.
        let (simulators, _) = host()
        let outcome = await Server.openURL(
            udid: "U", url: "https://example.com/x", devices: simulators
        )
        #expect(outcome == .opened(routing: .browser))
    }

    @Test func `should refuse a bare word as not a URL`() async {
        let (simulators, apps) = host()
        let outcome = await Server.openURL(udid: "U", url: "profile", devices: simulators)

        #expect(outcome == .notAURL)
        verify(apps).open(.any).called(0)
    }

    @Test func `should report an unknown device when opening a link on an unknown udid`() async {
        let (simulators, _) = host()
        let outcome = await Server.openURL(udid: "nope", url: "myapp://x", devices: simulators)
        #expect(outcome == .unknownDevice)
    }

    @Test func `should report a failed dispatch when the link cannot be opened`() async {
        let (simulators, _) = host(openSucceeds: false)
        let outcome = await Server.openURL(udid: "U", url: "myapp://x", devices: simulators)
        #expect(outcome == .dispatchFailed)
    }

    // MARK: - schemes

    @Test func `should answer the schemes route with the ranked scheme inventory`() async {
        let (simulators, _) = host(installed: [Self.myApp])
        let outcome = await Server.schemes(udid: "U", query: "", devices: simulators)

        #expect(outcome == .ok([
            SchemeSuggestion(scheme: "myapp", appName: "My App", bundleIdentifier: "com.example.MyApp"),
            SchemeSuggestion(scheme: "com.example.myapp", appName: "My App", bundleIdentifier: "com.example.MyApp"),
        ]))
    }

    @Test func `should rank the schemes against the typed query`() async {
        // Ranking is server-side so the browser never re-implements it.
        let (simulators, _) = host(installed: [
            InstalledApp(bundleIdentifier: "a", name: "A", schemes: ["superapp"]),
            InstalledApp(bundleIdentifier: "b", name: "B", schemes: ["app"]),
        ])
        let outcome = await Server.schemes(udid: "U", query: "app", devices: simulators)

        guard case .ok(let suggestions) = outcome else { return #expect(Bool(false)) }
        #expect(suggestions.map(\.scheme) == ["app", "superapp"])
    }

    @Test func `should report an unknown device when listing schemes on an unknown udid`() async {
        let (simulators, _) = host()
        #expect(await Server.schemes(udid: "nope", query: "", devices: simulators) == .unknownDevice)
    }

    @Test func `should report a failed listing when the installed apps cannot be read`() async {
        let (simulators, _) = host(listSucceeds: false)
        #expect(await Server.schemes(udid: "U", query: "", devices: simulators) == .listFailed)
    }

    // MARK: - what the browser actually receives

    private func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    @Test func `should tell the page a custom-scheme link reached the app, with no warning`() {
        let body = object(Server.openedJSONString(routing: .app))
        #expect(body["routing"] as? String == "app")
        #expect(body["warning"] == nil)
    }

    @Test func `should tell the page an https link went to the browser, with a Safari warning`() {
        // The copy lives server-side so the URL bar renders it rather
        // than keeping its own duplicate of the explanation.
        let body = object(Server.openedJSONString(routing: .browser))
        #expect(body["routing"] as? String == "browser")
        let warning = body["warning"] as? String
        #expect(warning?.contains("Safari") == true)
    }

    @Test func `should give each scheme suggestion what the URL bar needs to render a row`() {
        let json = Server.schemesJSONString([
            SchemeSuggestion(scheme: "myapp", appName: "My App", bundleIdentifier: "com.example.MyApp"),
        ])
        let rows = (object(json)["schemes"] as? [[String: Any]]) ?? []

        #expect(rows.count == 1)
        #expect(rows.first?["scheme"] as? String == "myapp")
        #expect(rows.first?["completion"] as? String == "myapp://")
        #expect(rows.first?["app"] as? String == "My App")
        #expect(rows.first?["bundleId"] as? String == "com.example.MyApp")
    }

    @Test func `should send an empty scheme list when no app declares a scheme`() {
        #expect((object(Server.schemesJSONString([]))["schemes"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test func `should refuse to open a link on a device that can't, naming it`() async {
        let phone = routeDevices(name: "han's iPhone")

        #expect(await Server.openURL(udid: "U", url: "myapp://x", devices: phone)
            == .refused(.unable(ability: "apps", device: "han's iPhone")))
    }

    @Test func `should answer the deep-link routes under the devices tree and a simulator's old one`() {
        for leaf in ["openurl", "schemes.json"] {
            #expect(Server.deviceRoutes(leaf) == ["/devices/:udid/\(leaf)", "/simulators/:udid/\(leaf)"])
        }
    }
}
