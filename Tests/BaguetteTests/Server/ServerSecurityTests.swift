import Testing
import Hummingbird
import HTTPTypes
import NIOCore
@testable import Baguette
@testable import BaguetteDevice

@Suite("Server browser security")
struct ServerSecurityTests {

    @Test func `should allow a direct loopback request that carries no Origin header`() {
        let request = Self.request(host: "127.0.0.1:8421")

        #expect(Server.isTrustedBrowserRequest(
            request, bindHost: "127.0.0.1", bindPort: 8421
        ))
    }

    @Test func `should allow a same-origin browser request on loopback`() {
        let request = Self.request(
            host: "localhost:8421",
            origin: "http://localhost:8421"
        )

        #expect(Server.isTrustedBrowserRequest(
            request, bindHost: "127.0.0.1", bindPort: 8421
        ))
    }

    @Test func `should reject a cross-site browser request to a loopback control route`() {
        let request = Self.request(
            host: "127.0.0.1:8421",
            origin: "https://example.test"
        )

        #expect(!Server.isTrustedBrowserRequest(
            request, bindHost: "127.0.0.1", bindPort: 8421
        ))
    }

    @Test func `should reject a DNS-rebind-shaped host when bound to loopback`() {
        let request = Self.request(
            host: "attacker.test:8421",
            origin: "http://attacker.test:8421"
        )

        #expect(!Server.isTrustedBrowserRequest(
            request, bindHost: "127.0.0.1", bindPort: 8421
        ))
    }

    @Test func `should reject a request that Fetch Metadata marks cross-site`() {
        let request = Self.request(
            host: "127.0.0.1:8421",
            origin: "http://127.0.0.1:8421",
            fetchSite: "cross-site"
        )

        #expect(!Server.isTrustedBrowserRequest(
            request, bindHost: "127.0.0.1", bindPort: 8421
        ))
    }

    @Test func `should allow a proxied request whose Host names an allowed host`() {
        let request = Self.request(host: "sim.example.test")

        #expect(Server.isTrustedBrowserRequest(
            request, bindHost: "127.0.0.1", bindPort: 8421,
            allowedHosts: ["sim.example.test"]
        ))
    }

    @Test func `should allow a browser origin on an allowed host regardless of port`() {
        let request = Self.request(
            host: "sim.example.test",
            origin: "https://sim.example.test"
        )

        #expect(Server.isTrustedBrowserRequest(
            request, bindHost: "127.0.0.1", bindPort: 8421,
            allowedHosts: ["sim.example.test"]
        ))
    }

    @Test func `should allow a subdomain when the allowed host is a wildcard`() {
        let request = Self.request(
            host: "device-1.sim.example.test",
            origin: "https://device-1.sim.example.test"
        )

        #expect(Server.isTrustedBrowserRequest(
            request, bindHost: "127.0.0.1", bindPort: 8421,
            allowedHosts: ["*.example.test"]
        ))
    }

    @Test func `should still reject a host outside the allowed list`() {
        let request = Self.request(
            host: "attacker.test:8421",
            origin: "http://attacker.test:8421"
        )

        #expect(!Server.isTrustedBrowserRequest(
            request, bindHost: "127.0.0.1", bindPort: 8421,
            allowedHosts: ["sim.example.test"]
        ))
    }

    @Test func `should reject a request to an allowed host when its Origin is foreign`() {
        let request = Self.request(
            host: "sim.example.test",
            origin: "https://attacker.test"
        )

        #expect(!Server.isTrustedBrowserRequest(
            request, bindHost: "127.0.0.1", bindPort: 8421,
            allowedHosts: ["sim.example.test"]
        ))
    }

    @Test func `should trust an allowed-host origin calling another allowed host`() {
        let request = Self.request(
            host: "sim.example.test",
            origin: "https://app.example.test"
        )

        #expect(Server.isTrustedBrowserRequest(
            request, bindHost: "127.0.0.1", bindPort: 8421,
            allowedHosts: ["sim.example.test", "app.example.test"]
        ))
    }

    @Test func `should trust an allowed-host origin when the proxy rewrites Host to loopback`() {
        let request = Self.request(
            host: "localhost:8421",
            origin: "https://sim.example.test"
        )

        #expect(Server.isTrustedBrowserRequest(
            request, bindHost: "127.0.0.1", bindPort: 8421,
            allowedHosts: ["sim.example.test"]
        ))
    }

    @Test func `should trust an allowed-host origin even when Fetch Metadata says cross-site`() {
        let request = Self.request(
            host: "sim.example.test",
            origin: "https://app.example.test",
            fetchSite: "cross-site"
        )

        #expect(Server.isTrustedBrowserRequest(
            request, bindHost: "127.0.0.1", bindPort: 8421,
            allowedHosts: ["sim.example.test", "app.example.test"]
        ))
    }

    @Test func `should echo only an allowed origin back for CORS`() {
        #expect(Server.corsAllowedOrigin(
            "https://app.example.test",
            allowedHosts: ["app.example.test"]
        ) == "https://app.example.test")

        #expect(Server.corsAllowedOrigin(
            "https://attacker.test",
            allowedHosts: ["app.example.test"]
        ) == nil)

        #expect(Server.corsAllowedOrigin(nil, allowedHosts: ["app.example.test"]) == nil)
    }

    @Test func `should answer a CORS preflight only for an allowed origin`() {
        let head = HTTPRequest(
            method: .options,
            scheme: nil,
            authority: "sim.example.test",
            path: "/simulators/UDID/boot",
            headerFields: [
                .origin: "https://app.example.test",
                .accessControlRequestMethod: "POST",
                .accessControlRequestHeaders: "content-type",
            ]
        )
        let request = Request(head: head, body: .init(buffer: ByteBuffer()))

        let response = Server.corsPreflightResponse(request, allowedHosts: ["app.example.test"])
        #expect(response?.status == .noContent)
        #expect(response?.headers[.accessControlAllowOrigin] == "https://app.example.test")
        #expect(response?.headers[.accessControlAllowMethods] == "POST")
        #expect(response?.headers[.accessControlAllowHeaders] == "content-type")

        #expect(Server.corsPreflightResponse(request, allowedHosts: ["other.test"]) == nil)
    }

    @Test func `should forbid foreign sites from framing the served pages`() {
        let csp = HTTPField.Name("Content-Security-Policy")!

        for asset in ["sim.html", "farm/farm.html"] {
            let response = Server.staticAsset(asset)

            #expect(response.headers[csp] == "frame-ancestors 'none'")
        }
    }

    private static func request(
        host: String,
        origin: String? = nil,
        fetchSite: String? = nil
    ) -> Request {
        var headers: HTTPFields = [:]
        if let origin { headers[.origin] = origin }
        if let fetchSite { headers[HTTPField.Name("Sec-Fetch-Site")!] = fetchSite }

        let head = HTTPRequest(
            method: .post,
            scheme: nil,
            authority: host,
            path: "/simulators/UDID/boot",
            headerFields: headers
        )
        return Request(head: head, body: .init(buffer: ByteBuffer()))
    }
}
