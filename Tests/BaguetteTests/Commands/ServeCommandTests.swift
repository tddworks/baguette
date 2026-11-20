import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDevice
@testable import WebRTCKit

/// `baguette serve`: which plugins it offers, and how it says so. The
/// server it composes and binds is integration-only.
@Suite("Serve command")
struct ServeCommandTests {

    private func authoring() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("serve-\(UUID())")
        let plugin = root.appendingPathComponent("probe-test")
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        try Data("""
        { "name": "probe-test", "version": "1.0.0", "apiVersion": 1,
          "contributes": { "commands": [ { "id": "go", "title": "Go", "run": ["true"] } ] } }
        """.utf8).write(to: plugin.appendingPathComponent(FileSystemPlugins.manifestFilename))
        return root
    }

    @Test func `should ask the STUN server it is given for each viewer's public address`() throws {
        #expect(try ServeCommand.parse(["--stun", "stun:198.51.100.4:3478"]).stun
            == STUNServer(address: DatagramAddress(ip: [198, 51, 100, 4], port: 3478)))
        #expect(try ServeCommand.parse([]).stun == nil)
        #expect(throws: (any Error).self) { try ServeCommand.parse(["--stun", "turn:example.com"]) }
    }

    @Test func `should relay through the TURN server it is given, as the user it names`() throws {
        let command = try ServeCommand.parse(["--turn", "turn:198.51.100.4:3478", "--turn-user", "baguette", "--turn-pass", "secret"])

        #expect(command.turn == TURNServer(address: DatagramAddress(ip: [198, 51, 100, 4], port: 3478),
                                           credentials: TURNCredentials(username: "baguette", password: "secret")))
        #expect(try ServeCommand.parse([]).turn == nil)
        #expect(throws: (any Error).self) { try ServeCommand.parse(["--turn", "turn:198.51.100.4:3478"]) }
    }

    @Test func `should keep WebRTC media to the ports it is given`() throws {
        #expect(try ServeCommand.parse(["--webrtc-ports", "8190-8194"]).mediaPorts == MediaPorts(8190...8194))
        #expect(try ServeCommand.parse([]).mediaPorts == .any)
        #expect(throws: (any Error).self) { try ServeCommand.parse(["--webrtc-ports", "lots"]) }
    }

    @Test func `should offer no plugin at all when told to ignore them`() throws {
        let dir = try authoring()
        defer { try? FileManager.default.removeItem(at: dir) }

        let command = try ServeCommand.parse(["--no-plugins", "--plugin-dir", dir.path])

        #expect(try command.plugins.all().isEmpty)
    }

    @Test func `should offer the plugins in the directories given`() throws {
        let dir = try authoring()
        defer { try? FileManager.default.removeItem(at: dir) }

        let command = try ServeCommand.parse(["--plugin-dir", dir.path])

        #expect(try command.plugins.all().contains { $0.id == "probe-test" })
    }

    @Test func `should name each plugin it offers, with its version`() async throws {
        let dir = try authoring()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plugins = FileSystemPlugins(roots: [dir])

        let ran = try await run(reaching: reaching(noDevices())) { ServeCommand.announce(plugins) }

        #expect(ran.told == ["plugin: probe-test 1.0.0"])
    }
}
