import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// `GET /mac-frames.json`: the Mac frames installed on this Mac that a
/// display of the asked size fits — what the page's frame picker offers.
@Suite("MacFramesRouter")
struct MacFramesRouterTests {
    static func installed(_ names: [String]) -> MacFrames {
        MacFrames(folder: URL(fileURLWithPath: "/frames")) { url in
            names.contains(url.deletingPathExtension().lastPathComponent) ? Data("png".utf8) : nil
        }
    }

    @Test func `should offer the installed frames a display of the asked size fits`() async throws {
        let frames = Self.installed(["iMac 24-inch", "iMac 27-inch", "MacBook Pro 14-inch (M4)"])
        try await InProcessServer(macFrames: frames).test { client in
            let response = try await client.send(.get, "/mac-frames.json?width=2560&height=1440")
            #expect(response.status == .ok)
            #expect(response.json["frames"] as? [String] == ["iMac 24-inch", "iMac 27-inch"])
        }
    }

    @Test func `should offer no frames when none installed fits the display`() async throws {
        try await InProcessServer(macFrames: Self.installed(["iMac 27-inch"])).test { client in
            let response = try await client.send(.get, "/mac-frames.json?width=1440&height=2560")
            #expect(response.json["frames"] as? [String] == [])
        }
    }

    @Test func `should refuse a request without the display's size`() async throws {
        try await InProcessServer(macFrames: Self.installed([])).test { client in
            #expect(await client.status(.get, "/mac-frames.json") == .badRequest)
            #expect(await client.status(.get, "/mac-frames.json?width=wide&height=1") == .badRequest)
        }
    }
}
