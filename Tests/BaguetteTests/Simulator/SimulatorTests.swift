import Testing
import Foundation
import Mockable
@testable import Baguette

@Suite("Simulator")
struct SimulatorTests {

    // MARK: - identity & state

    @Test func `holds udid name state and runtime`() {
        let s = Simulator(
            udid: "u1", name: "iPhone 17", state: .booted,
            runtime: "iOS 26.4",
            host: MockSimulators()
        )
        #expect(s.udid == "u1")
        #expect(s.name == "iPhone 17")
        #expect(s.state == .booted)
        #expect(s.runtime == "iOS 26.4")
    }

    @Test func `equality ignores the host`() {
        let a = Simulator(udid: "u1", name: "X", state: .booted, host: MockSimulators())
        let b = Simulator(udid: "u1", name: "X", state: .booted, host: MockSimulators())
        #expect(a == b)
    }

    @Test func `equality differs on stored fields`() {
        let host = MockSimulators()
        let booted = Simulator(udid: "u1", name: "X", state: .booted, host: host)
        let down   = Simulator(udid: "u1", name: "X", state: .shutdown, host: host)
        #expect(booted != down)
    }

    // MARK: - semantic flags

    @Test func `canStream is true only when booted`() {
        let host = MockSimulators()
        for state in [Simulator.State.creating, .shutdown, .booting, .shuttingDown] {
            #expect(!Simulator(udid: "u", name: "n", state: state, host: host).canStream)
        }
        #expect(Simulator(udid: "u", name: "n", state: .booted, host: host).canStream)
    }

    @Test func `canAcceptInput is true only when booted`() {
        let host = MockSimulators()
        for state in [Simulator.State.creating, .shutdown, .booting, .shuttingDown] {
            #expect(!Simulator(udid: "u", name: "n", state: state, host: host).canAcceptInput)
        }
        #expect(Simulator(udid: "u", name: "n", state: .booted, host: host).canAcceptInput)
    }

    // MARK: - rich-domain verbs

    @Test func `boot delegates to the host`() throws {
        let host = MockSimulators()
        given(host).boot(.any).willReturn()
        let s = Simulator(udid: "u1", name: "X", state: .shutdown, host: host)

        try s.boot()

        verify(host).boot(.value(s)).called(1)
    }

    @Test func `boot rethrows host errors`() {
        let host = MockSimulators()
        given(host).boot(.any).willThrow(SimulatorError.bootFailed)
        let s = Simulator(udid: "u1", name: "X", state: .shutdown, host: host)

        #expect(throws: SimulatorError.bootFailed) { try s.boot() }
    }

    @Test func `shutdown delegates to the host`() throws {
        let host = MockSimulators()
        given(host).shutdown(.any).willReturn()
        let s = Simulator(udid: "u1", name: "X", state: .booted, host: host)

        try s.shutdown()

        verify(host).shutdown(.value(s)).called(1)
    }

    @Test func `shutdown rethrows host errors`() {
        let host = MockSimulators()
        given(host).shutdown(.any).willThrow(SimulatorError.shutdownFailed)
        let s = Simulator(udid: "u1", name: "X", state: .booted, host: host)

        #expect(throws: SimulatorError.shutdownFailed) { try s.shutdown() }
    }

    // MARK: - capabilities

    @Test func `screen delegates to the host`() {
        let host = MockSimulators()
        let stubScreen = MockScreen()
        given(host).screen(for: .any).willReturn(stubScreen)
        let s = Simulator(udid: "u1", name: "X", state: .booted, host: host)

        let screen = s.screen()

        #expect(screen === stubScreen)
        verify(host).screen(for: .value(s)).called(1)
    }

    @Test func `input delegates to the host`() {
        let host = MockSimulators()
        let stubInput = MockInput()
        given(host).input(for: .any).willReturn(stubInput)
        let s = Simulator(udid: "u1", name: "X", state: .booted, host: host)

        let input = s.input()

        verify(host).input(for: .value(s)).called(1)
        _ = input  // silence unused
    }

    @Test func `chrome looks up assets by device name in the chromes aggregate`() {
        let host = MockSimulators()
        let chromes = MockChromes()
        let assets = DeviceChromeAssets(
            chrome: DeviceChrome(
                identifier: "phone11",
                screenInsets: Insets(top: 0, left: 0, bottom: 0, right: 0),
                outerCornerRadius: 0, buttons: [],
                compositeImageName: "X"
            ),
            composite: ChromeImage(data: Data(), size: Size(width: 1, height: 1))
        )
        given(chromes).assets(forDeviceName: .value("iPhone 17 Pro")).willReturn(assets)
        let s = Simulator(udid: "u1", name: "iPhone 17 Pro", state: .booted, host: host)

        let result = s.chrome(in: chromes)

        #expect(result?.chrome.identifier == "phone11")
        verify(chromes).assets(forDeviceName: .value("iPhone 17 Pro")).called(1)
    }

    // Cloned simulators carry a user-given `name` (e.g. "iPhone 17 pro
    // max clone 1") that no longer matches a `.simdevicetype` bundle.
    // The chrome bundle lives at the device-type name, so chrome
    // lookup must key off `deviceTypeName`, not the display name.
    @Test func `chrome looks up assets by device-type name when it differs from display name`() {
        let host = MockSimulators()
        let chromes = MockChromes()
        let assets = DeviceChromeAssets(
            chrome: DeviceChrome(
                identifier: "phone11",
                screenInsets: Insets(top: 0, left: 0, bottom: 0, right: 0),
                outerCornerRadius: 0, buttons: [],
                compositeImageName: "X"
            ),
            composite: ChromeImage(data: Data(), size: Size(width: 1, height: 1))
        )
        given(chromes).assets(forDeviceName: .value("iPhone 17 Pro Max")).willReturn(assets)
        let s = Simulator(
            udid: "u1",
            name: "iPhone 17 pro max clone 1",
            state: .booted,
            deviceTypeName: "iPhone 17 Pro Max",
            host: host
        )

        let result = s.chrome(in: chromes)

        #expect(result?.chrome.identifier == "phone11")
        verify(chromes).assets(forDeviceName: .value("iPhone 17 Pro Max")).called(1)
    }

    // Backwards-compat: when no explicit `deviceTypeName` is given,
    // fall back to the display `name` so existing call sites keep
    // working unchanged.
    @Test func `chrome falls back to display name when deviceTypeName is omitted`() {
        let host = MockSimulators()
        let chromes = MockChromes()
        given(chromes).assets(forDeviceName: .value("iPhone 17 Pro")).willReturn(nil)
        let s = Simulator(udid: "u1", name: "iPhone 17 Pro", state: .booted, host: host)

        _ = s.chrome(in: chromes)

        verify(chromes).assets(forDeviceName: .value("iPhone 17 Pro")).called(1)
    }

    // MARK: - presentation

    @Test func `json shape matches the list subcommand contract`() {
        let s = Simulator(
            udid: "u1", name: "iPhone 17", state: .booted,
            runtime: "iOS 26.4",
            host: MockSimulators()
        )
        #expect(s.json ==
            "{\"udid\":\"u1\",\"name\":\"iPhone 17\",\"state\":\"Booted\",\"runtime\":\"iOS 26.4\"}")
    }

    @Test func `runtime is empty string when not provided`() {
        let s = Simulator(
            udid: "u1", name: "iPhone 17", state: .shutdown,
            host: MockSimulators()
        )
        #expect(s.runtime == "")
    }

    // The `state` strings end up in the list output and the serve UI;
    // exhaustively pin every enum case so a typo or new case is caught.
    @Test func `State description covers all cases`() {
        #expect(Simulator.State.creating.description == "Creating")
        #expect(Simulator.State.shutdown.description == "Shutdown")
        #expect(Simulator.State.booting.description == "Booting")
        #expect(Simulator.State.booted.description == "Booted")
        #expect(Simulator.State.shuttingDown.description == "ShuttingDown")
    }
}
