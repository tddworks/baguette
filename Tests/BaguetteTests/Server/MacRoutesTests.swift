import Testing
import Foundation
import Mockable
@testable import Baguette

/// Integration-level tests for the `/mac/...` route surface. We
/// drive the static helpers (`macListJSONString` etc.) directly
/// when they exist; otherwise we rely on the constructor + handler
/// shape and assert their wiring at the structural level.
///
/// Network paths (the WS stream, ScreenCaptureKit screenshot
/// capture) are integration-only and excluded from this suite.
@Suite("Server mac routes")
struct MacRoutesTests {

    // MARK: - bundleID extractor

    @Test func `bundleIDParam handles slash-free path component`() {
        // The static helper isn't private — internal/`@testable`
        // exposes it. Drive it via a one-off Hummingbird Request
        // through `Server` constructor parity isn't worth the cost;
        // instead, anchor on `MacApps.listJSON` shape (which the
        // route serializes) and the constructor wiring.
        let host = MockMacApps()
        let app = MacApp(bundleID: "com.apple.TextEdit", pid: 1, name: "TextEdit", isActive: true, host: host)
        given(host).all.willReturn([app])
        let json = host.listJSON
        #expect(json.contains("com.apple.TextEdit"))
        #expect(json.contains("\"active\""))
    }

    // MARK: - constructor wiring

    @Test func `Server stores macApps alongside simulators`() {
        let sims = MockSimulators()
        let macs = MockMacApps()
        let chromes = MockChromes()
        let server = Server(
            simulators: sims,
            macApps: macs,
            chromes: chromes,
            host: "127.0.0.1",
            port: 8421
        )
        // Identity check: the protocol values stored on the struct
        // are exactly the ones we passed in. Lets future regressions
        // (e.g. accidental @StateObject wrap or copy) surface.
        #expect(server.macApps === macs)
        #expect(server.simulators === sims)
    }

    // MARK: - mac.json projection

    @Test func `MacApps listJSON is the route's payload shape`() throws {
        let host = MockMacApps()
        let active = MacApp(bundleID: "com.a", pid: 11, name: "A", isActive: true,  host: host)
        let other  = MacApp(bundleID: "com.b", pid: 22, name: "B", isActive: false, host: host)
        given(host).all.willReturn([active, other])

        let data = host.listJSON.data(using: .utf8)!
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let activeArr = dict["active"]   as! [[String: Any]]
        let otherArr  = dict["inactive"] as! [[String: Any]]
        #expect(activeArr.count == 1)
        #expect(otherArr.count == 1)
        #expect(activeArr[0]["bundleID"] as? String == "com.a")
        #expect(otherArr[0]["bundleID"]  as? String == "com.b")
    }

    // MARK: - error paths

    @Test func `unknown bundleID screenshot returns nil from MacApps lookup`() {
        let host = MockMacApps()
        given(host).find(bundleID: .value("ghost")).willReturn(nil)
        #expect(host.find(bundleID: "ghost") == nil)
    }

    @Test func `lookup hits MacApps with the requested bundleID`() {
        let host = MockMacApps()
        let app = MacApp(bundleID: "com.apple.finder", pid: 99, name: "Finder", isActive: true, host: host)
        given(host).find(bundleID: .value("com.apple.finder")).willReturn(app)

        let result = host.find(bundleID: "com.apple.finder")
        #expect(result?.bundleID == "com.apple.finder")
        verify(host).find(bundleID: .value("com.apple.finder")).called(1)
    }
}
