import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDevice

/// Handler-level coverage for the interface routes. As with the
/// status-bar routes, the pure parse + dispatch helpers are tested
/// rather than the Hummingbird `Response` wrappers — every branch is
/// driven with one device's `MockInterface`.
@Suite("Server interface routes")
struct InterfaceRoutesTests {

    // MARK: - parsing the request

    @Test func `should accept an interface update that names any one of the three settings`() {
        // The three travel together but are set independently — a panel
        // flipping only dark mode shouldn't have to restate the rest.
        #expect(
            Server.parseInterfaceUpdate(json: #"{"appearance":"dark"}"#)
                == InterfaceUpdate(appearance: .dark)
        )
        #expect(
            Server.parseInterfaceUpdate(json: #"{"increaseContrast":"enabled"}"#)
                == InterfaceUpdate(increaseContrast: .enabled)
        )
        #expect(
            Server.parseInterfaceUpdate(json: #"{"contentSize":"increment"}"#)
                == InterfaceUpdate(contentSize: .increment)
        )
    }

    @Test func `should accept an interface update carrying all three settings at once`() {
        let json = #"{"appearance":"dark","increaseContrast":"enabled","contentSize":"accessibility-large"}"#
        #expect(Server.parseInterfaceUpdate(json: json) == InterfaceUpdate(
            appearance: .dark,
            increaseContrast: .enabled,
            contentSize: .size(.accessibilityLarge)
        ))
    }

    @Test func `should refuse a malformed interface update body`() {
        #expect(Server.parseInterfaceUpdate(json: "not json") == nil)
    }

    @Test func `should refuse an interface value that can only be read, never set`() {
        // `unknown` is what a shut-down device *answers*. Echoing it
        // back as an instruction is a caller bug, and it fails here
        // rather than as a confusing simctl usage error.
        #expect(Server.parseInterfaceUpdate(json: #"{"appearance":"unknown"}"#) == nil)
        #expect(Server.parseInterfaceUpdate(json: #"{"contentSize":"unsupported"}"#) == nil)
        #expect(Server.parseInterfaceUpdate(json: #"{"increaseContrast":"maybe"}"#) == nil)
    }

    @Test func `should set nothing when the interface update body is empty`() {
        // Distinguishable from a parse failure: valid JSON, nothing to do.
        #expect(Server.parseInterfaceUpdate(json: "{}") == InterfaceUpdate())
        #expect(InterfaceUpdate().isEmpty)
        #expect(!InterfaceUpdate(appearance: .dark).isEmpty)
    }

    // MARK: - reading

    @Test func `should read all three interface settings in one call`() async throws {
        let simulators = Self.simulators(
            appearance: .dark, contrast: .enabled, contentSize: .accessibilityLarge
        )
        guard case .ok(let json) = await Server.readInterface(udid: "U", devices: simulators)
        else { Issue.record("expected .ok"); return }

        let parsed = try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        #expect(parsed["appearance"] as? String == "dark")
        #expect(parsed["increaseContrast"] as? String == "enabled")
        #expect(parsed["contentSize"] as? String == "accessibility-large")
    }

    @Test func `should answer unknown rather than fail when the device is shut down`() async {
        // The panel needs to be able to say "boot the device" — which
        // it can only do if the read succeeds and reports unknown.
        let simulators = Self.simulators(
            appearance: .unknown, contrast: .unknown, contentSize: .unknown
        )
        guard case .ok(let json) = await Server.readInterface(udid: "U", devices: simulators)
        else { Issue.record("expected .ok"); return }
        #expect(json.contains("\"appearance\":\"unknown\""))
    }

    @Test func `should report an unknown device when reading its interface settings`() async {
        let simulators = routeDevices()
        #expect(await Server.readInterface(udid: "nope", devices: simulators) == .unknownDevice)
    }

    // MARK: - applying

    @Test func `should change only the interface settings the body named`() async {
        let interface = MockInterface()
        given(interface).setAppearance(.any).willReturn(())
        given(interface).setIncreaseContrast(.any).willReturn(())
        given(interface).setContentSize(.any).willReturn(())

        let outcome = await Server.applyInterface(
            udid: "U",
            update: InterfaceUpdate(appearance: .dark),
            devices: Self.simulators(interface: interface)
        )

        #expect(outcome == .ok(applied: ["appearance"]))
        verify(interface).setAppearance(.value(.dark)).called(1)
        verify(interface).setIncreaseContrast(.any).called(0)
        verify(interface).setContentSize(.any).called(0)
    }

    @Test func `should change all three interface settings when the body names all three`() async {
        let interface = MockInterface()
        given(interface).setAppearance(.any).willReturn(())
        given(interface).setIncreaseContrast(.any).willReturn(())
        given(interface).setContentSize(.any).willReturn(())

        _ = await Server.applyInterface(
            udid: "U",
            update: InterfaceUpdate(
                appearance: .light, increaseContrast: .disabled, contentSize: .decrement
            ),
            devices: Self.simulators(interface: interface)
        )

        verify(interface).setAppearance(.value(.light)).called(1)
        verify(interface).setIncreaseContrast(.value(.disabled)).called(1)
        verify(interface).setContentSize(.value(.decrement)).called(1)
    }

    @Test func `should report a failure, not a silent success, when simctl cannot change a setting`() async {
        let interface = MockInterface()
        given(interface).setAppearance(.any).willThrow(InterfaceError.simctlFailed(status: 3))

        let outcome = await Server.applyInterface(
            udid: "U",
            update: InterfaceUpdate(appearance: .dark),
            devices: Self.simulators(interface: interface)
        )
        guard case .failed(let message, let applied) = outcome else {
            Issue.record("expected .failed, got \(outcome)"); return
        }
        #expect(message.contains("3"))
        // Nothing landed before the very first setter threw.
        #expect(applied.isEmpty)
    }

    @Test func `should name the settings that did apply when a later one fails`() async {
        // Each setting is its own spawn, so a three-field body is three
        // chances to fail halfway. A bare failure would tell the caller
        // nothing changed, when in fact the appearance already had.
        let interface = MockInterface()
        given(interface).setAppearance(.any).willReturn(())
        given(interface).setIncreaseContrast(.any)
            .willThrow(InterfaceError.simctlFailed(status: 3))
        given(interface).setContentSize(.any).willReturn(())

        let outcome = await Server.applyInterface(
            udid: "U",
            update: InterfaceUpdate(
                appearance: .dark, increaseContrast: .enabled, contentSize: .increment
            ),
            devices: Self.simulators(interface: interface)
        )
        guard case .failed(let message, let applied) = outcome else {
            Issue.record("expected .failed, got \(outcome)"); return
        }
        #expect(applied == ["appearance"])
        #expect(message.contains("3"))
        // The setting after the failure is not attempted — a body is
        // applied in order and stops where it broke.
        verify(interface).setContentSize(.any).called(0)
    }

    @Test func `should name every setting it changed when the whole update lands`() async {
        let interface = MockInterface()
        given(interface).setAppearance(.any).willReturn(())
        given(interface).setIncreaseContrast(.any).willReturn(())
        given(interface).setContentSize(.any).willReturn(())

        let outcome = await Server.applyInterface(
            udid: "U",
            update: InterfaceUpdate(
                appearance: .light, increaseContrast: .disabled, contentSize: .decrement
            ),
            devices: Self.simulators(interface: interface)
        )
        guard case .ok(let applied) = outcome else {
            Issue.record("expected .ok, got \(outcome)"); return
        }
        #expect(applied == ["appearance", "increaseContrast", "contentSize"])
    }

    @Test func `should tell the caller which settings applied and any error, in one shape`() throws {
        // Used when the post-change read fails: the settings landed,
        // but the device won't say what it now reads as. `{"ok":true}`
        // claimed success in a shape the caller couldn't use.
        let parsed = try #require(
            JSONSerialization.jsonObject(
                with: Data(Server.appliedJSON(["appearance"], error: "simctl exited 3").utf8)
            ) as? [String: Any]
        )
        #expect(parsed["applied"] as? [String] == ["appearance"])
        #expect(parsed["error"] as? String == "simctl exited 3")
        #expect(parsed["ok"] as? Bool == false)

        let clean = try #require(
            JSONSerialization.jsonObject(
                with: Data(Server.appliedJSON(["appearance", "contentSize"]).utf8)
            ) as? [String: Any]
        )
        #expect(clean["applied"] as? [String] == ["appearance", "contentSize"])
        #expect(clean["ok"] as? Bool == true)
        #expect(clean["error"] == nil)
    }

    @Test func `should report an unknown device when changing its interface settings`() async {
        let simulators = routeDevices()
        let outcome = await Server.applyInterface(
            udid: "nope", update: InterfaceUpdate(appearance: .dark), devices: simulators
        )
        #expect(outcome == .unknownDevice)
    }

    @Test func `should refuse the interface of a device that has none, naming it`() async {
        #expect(await Server.readInterface(udid: "U", devices: routeDevices(name: "han's iPhone"))
            == .refused(.unable(ability: "interface", device: "han's iPhone")))
    }

    @Test func `should answer the interface routes under the devices tree and a simulator's old one`() {
        for leaf in ["interface.json", "interface"] {
            #expect(Server.deviceRoutes(leaf) == ["/devices/:udid/\(leaf)", "/simulators/:udid/\(leaf)"])
        }
    }

    // MARK: - helpers

    static func simulators(
        appearance: InterfaceAppearance = .light,
        contrast: InterfaceContrast = .disabled,
        contentSize: ContentSize = .large
    ) -> any Devices {
        let interface = MockInterface()
        given(interface).appearance().willReturn(appearance)
        given(interface).increaseContrast().willReturn(contrast)
        given(interface).contentSize().willReturn(contentSize)
        return simulators(interface: interface)
    }

    static func simulators(interface: MockInterface) -> any Devices {
        routeDevices { $0.register(.interface) { interface } }
    }
}
