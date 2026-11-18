import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// `baguette list`, `lifetime` and `input` against what a test hands them.
@Suite("Session commands")
struct SessionCommandsTests {

    private struct Refused: Error, CustomStringConvertible {
        var description: String { "refused" }
    }

    // MARK: - list

    private func simulator() -> MockSimulator {
        let sim = MockSimulator()
        given(sim).udid.willReturn("S")
        given(sim).name.willReturn("iPhone 17")
        given(sim).state.willReturn(.booted)
        given(sim).runtime.willReturn("iOS 27.0")
        given(sim).deviceTypeName.willReturn("iPhone 17")
        given(sim).metadata.willReturn(SimulatorMetadata())
        return sim
    }

    private func phone() -> any Devices {
        let device = MockDevice()
        given(device).id.willReturn("P")
        given(device).name.willReturn("han's iPhone")
        given(device).state.willReturn(.ready)
        given(device).kind.willReturn(DeviceKind(platform: .iOS, reality: .physical, model: "iPhone 17 Pro"))
        given(device).abilities.willReturn(Abilities(device: "han's iPhone"))
        let devices = MockDevices()
        given(devices).all.willReturn([device])
        given(devices).find(id: .any).willReturn(nil)
        return devices
    }

    @Test func `should list each simulator and then each physical device, one line each`() async throws {
        let ran = try await run(reaching: reaching(phone(), simulators: [simulator()])) {
            try ListCommand.parse([]).run()
        }

        #expect(ran.said == [
            #"{"udid":"S","name":"iPhone 17","state":"Booted","runtime":"iOS 27.0"}"#,
            #"{"udid":"P","name":"han's iPhone","state":"ready","runtime":"","reality":"physical","model":"iPhone 17 Pro"}"#,
        ])
    }

    @Test func `should list the simulators as one running and available envelope when asked for JSON`() async throws {
        let ran = try await run(reaching: reaching(phone(), simulators: [simulator()])) {
            try ListCommand.parse(["--json"]).run()
        }

        let envelope = try #require(
            JSONSerialization.jsonObject(with: Data(ran.said.joined().utf8)) as? [String: [[String: Any]]])
        #expect(envelope["running"]?.map { $0["udid"] as? String } == ["S"])
        #expect(envelope["available"]?.isEmpty == true)
    }

    // MARK: - lifetime

    private final class Written: @unchecked Sendable {
        var lifetime: SimulatorLifetime?
    }

    private func settings(_ current: SimulatorLifetime, running: Bool = false, failing: Bool = false,
                          into written: Written = Written()) -> SimulatorAppSettings {
        SimulatorAppSettings(
            lifetime: { current },
            write: { lifetime in
                if failing { throw Refused() }
                written.lifetime = lifetime
            },
            appRunning: { running })
    }

    private func lifetime(_ argv: [String], _ settings: SimulatorAppSettings) async throws -> CommandRun {
        try await SimulatorAppSettings.$current.withValue(settings) {
            try await run(reaching: reaching(noDevices())) { try LifetimeCommand.parse(argv).run() }
        }
    }

    @Test func `should report the policy in force when no flag is given`() async throws {
        let ran = try await lifetime([], settings(.detached))

        #expect(ran.said == LifetimeCommand.report(.detached, colored: false))
    }

    @Test func `should leave devices booted when asked to detach`() async throws {
        let written = Written()

        let ran = try await lifetime(["--detach"], settings(.appleDefault, into: written))

        #expect(written.lifetime == .detached)
        #expect(ran.told == [LifetimeCommand.headline(.detached)])
    }

    @Test func `should still change the policy while Simulator.app is running`() async throws {
        let written = Written()

        let ran = try await lifetime(["--shutdown"], settings(.detached, running: true, into: written))

        #expect(written.lifetime == .appleDefault)
        #expect(ran.told == [LifetimeCommand.headline(.appleDefault)])
    }

    @Test func `should say the policy is already set when nothing changes`() async throws {
        let written = Written()

        let ran = try await lifetime(["--detach"], settings(.detached, into: written))

        #expect(written.lifetime == nil)
        #expect(ran.told == ["Already set — \(LifetimeCommand.headline(.detached))"])
    }

    @Test func `should exit 1 when the policy can't be written`() async throws {
        let ran = try await lifetime(["--detach"], settings(.appleDefault, failing: true))

        #expect(ran.exit == 1)
        #expect(ran.told == ["Could not change the lifetime policy: refused"])
    }

    // MARK: - input

    private func inputting() -> any Devices {
        let touch = MockTouch()
        given(touch).tap(at: .any, size: .any, duration: .any, edge: .any).willReturn(true)
        let pasteboard = MockPasteboard()
        return routeDevices {
            $0.register(.touch) { touch }
            $0.register(.pasteboard) { pasteboard }
        }
    }

    private let tap = #"{"type":"tap","x":10,"y":20,"width":390,"height":844}"#

    @Test func `should answer each gesture piped in, one line each, until stdin ends`() async throws {
        let ran = try await run(try InputCommand.parse(["--udid", "U"]), on: inputting(),
                                terminal: Terminal(lines: [tap, tap]))

        #expect(ran.exit == 0)
        #expect(ran.said.count == 2)
        #expect(ran.said.allSatisfy { $0.contains(#""ok":true"#) })
        #expect(ran.told == ["Input session started, reading from stdin", "stdin closed, input session ending"])
    }

    @Test func `should answer describe, paste, copy and then-describe lines in the order piped in`() async throws {
        let touch = MockTouch()
        given(touch).tap(at: .any, size: .any, duration: .any, edge: .any).willReturn(false)
        let key = MockKey()
        given(key).key(.any, modifiers: .any, duration: .any).willReturn(true)
        let pasteboard = MockPasteboard()
        given(pasteboard).setText(.any).willReturn()
        given(pasteboard).syncToHost().willReturn()
        let lines = [
            #"{"type":"describe_ui"}"#,
            #"{"type":"paste","text":"hi","press":false}"#,
            #"{"type":"copy","press":false}"#,
            #"{"type":"tap","x":1,"y":2,"width":390,"height":844,"then_describe_ui":true}"#,
        ]

        let ran = try await run(try InputCommand.parse(["--udid", "U"]), on: routeDevices {
            $0.register(.touch) { touch }
            $0.register(.key) { key }
            $0.register(.pasteboard) { pasteboard }
        }, terminal: Terminal(lines: lines))

        #expect(ran.said.count == 4)
        #expect(ran.said[0].contains("can't do accessibility"))
        #expect(ran.said[1] == #"{"ok":true}"#)
        #expect(ran.said[2] == #"{"ok":true}"#)
        #expect(ran.said[3].contains(#""ok":false"#))
    }

    @Test func `should exit 1 when CarPlay can't be turned on`() async throws {
        let external = MockExternalDisplays()
        given(external).enableCarPlay().willThrow(Refused())

        let ran = try await run(try InputCommand.parse(["--udid", "U", "--display", "carplay"]),
                                on: routeDevices { $0.register(.externalDisplays) { external } })

        #expect(ran.exit == 1)
        #expect(ran.told == ["display bind failed: refused"])
    }

    @Test func `should exit 1 when the device has nothing to touch`() async throws {
        let pasteboard = MockPasteboard()
        let ran = try await run(try InputCommand.parse(["--udid", "U"]),
                                on: routeDevices { $0.register(.pasteboard) { pasteboard } })

        #expect(ran.exit == 1)
        #expect(ran.told == ["iPhone 17 can't do touch"])
    }

    @Test func `should exit 1 when no CarPlay screen is attached`() async throws {
        let display = MockDisplay()
        given(display).resolve().willThrow(FramebufferSelectionError.noMatchingFramebuffer(.carPlay))
        let displays = MockDisplays()
        given(displays).carPlay.willReturn(display)

        let ran = try await run(
            try InputCommand.parse(["--udid", "U", "--display", "carplay", "--require-existing-display"]),
            on: routeDevices { $0.register(.displays) { displays } })

        #expect(ran.exit == 1)
        #expect(ran.told == [FramebufferSelectionError.noMatchingFramebuffer(.carPlay).message])
    }

    @Test func `should exit 1 when no device has the udid`() async throws {
        let ran = try await run(try InputCommand.parse(["--udid", "NOPE"]), on: inputting())

        #expect(ran.exit == 1)
        #expect(ran.told == ["Device NOPE not found"])
    }
}
