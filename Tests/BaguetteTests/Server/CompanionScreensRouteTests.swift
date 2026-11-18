import Foundation
import Mockable
import Testing

@testable import Baguette
@testable import BaguetteDevice

/// `GET /simulators/:udid/companion-screens.json` — what the focus-mode
/// screens rail asks before it offers anything. A device with no CarPlay
/// and no paired watch is a perfectly good answer, so only an unknown
/// udid is an error.
@Suite("Companion screens route")
struct CompanionScreensRouteTests {

    /// A simulator whose CarPlay plane resolves (or doesn't) and whose
    /// pairing table holds (or doesn't) a watch.
    private func simulator(carPlayBinds: Bool, watch: PairedWatch?) -> MockSimulator {
        let sim = MockSimulator()
        let display = MockDisplay()
        let displays = MockDisplays()
        let pairing = MockWatchPairing()
        if carPlayBinds {
            given(display).resolve().willReturn(
                DisplayBinding(
                    kind: .carPlay,
                    connectedScreenId: 3,
                    portName: "com.apple.framebuffer.display",
                    size: Size(width: 720, height: 480)
                )
            )
        } else {
            given(display).resolve().willThrow(FramebufferSelectionError.noMatchingPort(.carPlay))
        }
        given(displays).carPlay.willReturn(display)
        given(pairing).watch.willReturn(watch)
        given(sim).displays().willReturn(displays)
        given(sim).watchPairing().willReturn(pairing)
        return sim
    }

    @Test func `should offer both CarPlay and the watch when the device has both screens`() {
        let sim = simulator(
            carPlayBinds: true,
            watch: PairedWatch(udid: "WATCH-1", name: "Apple Watch Ultra 3", state: .ready)
        )

        let simulators = MockSimulators()
        given(simulators).find(udid: .value("PHONE-1")).willReturn(sim)
        Self.ready(sim)

        #expect(
            Server.readCompanionScreens(udid: "PHONE-1", devices: SimulatorDevices(simulators))
                == .ok("""
                    {"external":{"available":true,"height":480,"width":720},"watch":{"available":true,\
                    "name":"Apple Watch Ultra 3","state":"Booted","udid":"WATCH-1"}}
                    """)
        )
    }

    @Test func `should offer neither companion screen when the device has none`() {
        let sim = simulator(carPlayBinds: false, watch: nil)

        let simulators = MockSimulators()
        given(simulators).find(udid: .value("PHONE-1")).willReturn(sim)
        Self.ready(sim)

        #expect(
            Server.readCompanionScreens(udid: "PHONE-1", devices: SimulatorDevices(simulators))
                == .ok(#"{"external":{"available":false},"watch":{"available":false}}"#)
        )
    }

    @Test func `should fail only when the udid is unknown`() {
        let simulators = MockSimulators()
        given(simulators).find(udid: .any).willReturn(nil)

        #expect(
            Server.readCompanionScreens(udid: "nope", devices: SimulatorDevices(simulators)) == .unknownDevice
        )
    }

    /// Availability has to mean "we can stream it", not "the host lists
    /// something by that name".
    ///
    /// A device can carry a registered CarPlay screen that has no
    /// framebuffer behind it — Connected Screens names it, `simctl
    /// screenshot` times out waiting for surfaces, and the stream fails
    /// to bind. Reporting that screen as available lights the rail and
    /// opens a pane that can never paint, which is exactly the black
    /// rectangle this route exists to prevent. The bind is the same
    /// resolve the stream itself does, so the two can't disagree.
    @Test func `should not offer a CarPlay screen that is registered but won't bind`() {
        let sim = simulator(carPlayBinds: false, watch: nil)

        let simulators = MockSimulators()
        given(simulators).find(udid: .any).willReturn(sim)
        Self.ready(sim)

        #expect(
            Server.readCompanionScreens(udid: "PHONE-1", devices: SimulatorDevices(simulators))
                == .ok(#"{"external":{"available":false},"watch":{"available":false}}"#)
        )
    }

    // MARK: - route shape

    /// `udidParam` reads the udid **positionally** — second-to-last path
    /// segment — so a route that buries the udid deeper silently reports
    /// "unknown udid: <whatever segment happened to land there>". That
    /// is a 404 at runtime from a route that compiles fine, which is
    /// exactly how the first draft of the reattach route shipped
    /// (`/simulators/:udid/companion-screens/carplay` → "unknown udid:
    /// companion-screens"). Pin the paths against the rule.
    @Test func `should keep the udid second-to-last in every companion-screens route path`() {
        for path in [
            "/simulators/UDID-1/companion-screens.json",
            "/simulators/UDID-1/carplay-display",
        ] {
            #expect(Server.udid(inPath: path) == "UDID-1", "\(path)")
        }
    }

    @Test func `should decode a percent-encoded udid out of the path`() {
        #expect(Server.udid(inPath: "/simulators/A%2FB/carplay-display") == "A/B")
    }

    @Test func `should find no udid in a path too short to carry one`() {
        #expect(Server.udid(inPath: "/simulators") == "")
    }

    // MARK: - reattach

    /// Attaching a CarPlay display is a menu dance in Simulator.app —
    /// raise the device's window, I/O → External Displays → Disabled →
    /// CarPlay. baguette can drive it, so the rail offers a button
    /// rather than a paragraph of instructions.
    ///
    /// The answer is the *resulting* availability, read back the same
    /// way the rail reads it. A caller that just asked for a display
    /// needs to know whether it got one, and the menu click succeeding
    /// says nothing about whether a framebuffer appeared behind it.
    @Test func `should answer a CarPlay reattach with the display's availability afterwards`() throws {
        let sim = simulator(carPlayBinds: true, watch: nil)
        let external = MockExternalDisplays()
        given(external).reattachCarPlay().willReturn()
        given(sim).externalDisplays().willReturn(external)

        let simulators = MockSimulators()
        given(simulators).find(udid: .any).willReturn(sim)
        Self.ready(sim)

        #expect(
            Server.reattachCarPlay(udid: "PHONE-1", devices: SimulatorDevices(simulators))
                == .ok(#"{"external":{"available":true,"height":480,"width":720},"watch":{"available":false}}"#)
        )
        verify(external).reattachCarPlay().called(1)
    }

    /// The click can land and still leave nothing to stream. Reporting
    /// that as success would send the rail back to a pane that cannot
    /// paint — the exact failure the bind probe exists to prevent — so
    /// the honest answer is the unchanged availability.
    @Test func `should report the display still unavailable when a reattach attaches nothing`() throws {
        let sim = simulator(carPlayBinds: false, watch: nil)
        let external = MockExternalDisplays()
        given(external).reattachCarPlay().willReturn()
        given(sim).externalDisplays().willReturn(external)

        let simulators = MockSimulators()
        given(simulators).find(udid: .any).willReturn(sim)
        Self.ready(sim)

        #expect(
            Server.reattachCarPlay(udid: "PHONE-1", devices: SimulatorDevices(simulators))
                == .ok(#"{"external":{"available":false},"watch":{"available":false}}"#)
        )
    }

    /// Driving another app's menus needs Automation permission the user
    /// may never have granted. That is a thing to say out loud, not a
    /// silent no-op — the button would otherwise look broken.
    @Test func `should say why when the host refuses a CarPlay reattach`() throws {
        let sim = simulator(carPlayBinds: false, watch: nil)
        let external = MockExternalDisplays()
        given(external).reattachCarPlay()
            .willThrow(ExternalDisplaysError.enableFailed(status: 1))
        given(sim).externalDisplays().willReturn(external)

        let simulators = MockSimulators()
        given(simulators).find(udid: .any).willReturn(sim)
        Self.ready(sim)

        guard case .failed(let message) = Server.reattachCarPlay(
            udid: "PHONE-1", devices: SimulatorDevices(simulators)
        ) else {
            Issue.record("expected a failure outcome")
            return
        }
        #expect(message.contains("enableFailed"))
    }

    @Test func `should report an unknown device when reattaching CarPlay on an unknown udid`() {
        let simulators = MockSimulators()
        given(simulators).find(udid: .any).willReturn(nil)

        #expect(Server.reattachCarPlay(udid: "nope", devices: SimulatorDevices(simulators)) == .unknownDevice)
    }

    /// A shutdown device resolves nothing at all. That is an answer the
    /// rail renders as instructions, not a 500.
    @Test func `should still answer when the device resolves no display at all`() {
        let sim = MockSimulator()
        let displays = MockDisplays()
        let display = MockDisplay()
        let pairing = MockWatchPairing()
        given(display).resolve().willThrow(FramebufferSelectionError.screenIdUnavailable)
        given(displays).carPlay.willReturn(display)
        given(pairing).watch.willReturn(nil)
        given(sim).displays().willReturn(displays)
        given(sim).watchPairing().willReturn(pairing)

        let simulators = MockSimulators()
        given(simulators).find(udid: .any).willReturn(sim)
        Self.ready(sim)

        #expect(
            Server.readCompanionScreens(udid: "PHONE-1", devices: SimulatorDevices(simulators))
                == .ok(#"{"external":{"available":false},"watch":{"available":false}}"#)
        )
    }

    @Test func `should refuse companion screens for a device that has none, naming it`() {
        #expect(Server.readCompanionScreens(udid: "U", devices: routeDevices(name: "han's iPhone"))
            == .refused(.unable(ability: "displays", device: "han's iPhone")))
    }

    @Test func `should answer companion screens under the devices tree and a simulator's old one`() {
        for leaf in ["companion-screens.json", "carplay-display"] {
            #expect(Server.deviceRoutes(leaf) == ["/devices/:udid/\(leaf)", "/simulators/:udid/\(leaf)"])
        }
    }

    /// A booted simulator as `SimulatorDevices` reads it.
    static func ready(_ sim: MockSimulator) {
        given(sim).udid.willReturn("PHONE-1")
        given(sim).name.willReturn("iPhone 17")
        given(sim).state.willReturn(.booted)
        given(sim).runtime.willReturn("iOS 26.4")
        given(sim).deviceTypeName.willReturn("iPhone 17")
    }
}
