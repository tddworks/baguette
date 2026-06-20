import Testing
import Foundation
import Mockable
@testable import BaguetteCore

/// `Simulator` is a `@Mockable` protocol now — identity, state, and
/// the per-simulator capabilities live on the entity itself, not on
/// the aggregate. These tests cover the protocol's default-impl
/// extensions (`canStream`, `canAcceptInput`, `json`,
/// `chrome(in:)`); identity getters and capability factories are
/// just protocol contracts and don't carry behaviour worth testing.
@Suite("Simulator")
struct SimulatorTests {

    // MARK: - semantic flags

    @Test func `canStream is true only when booted`() {
        for state in [SimulatorState.creating, .shutdown, .booting, .shuttingDown] {
            let s = MockSimulator()
            given(s).state.willReturn(state)
            #expect(!s.canStream)
        }
        let booted = MockSimulator()
        given(booted).state.willReturn(.booted)
        #expect(booted.canStream)
    }

    @Test func `canAcceptInput is true only when booted`() {
        for state in [SimulatorState.creating, .shutdown, .booting, .shuttingDown] {
            let s = MockSimulator()
            given(s).state.willReturn(state)
            #expect(!s.canAcceptInput)
        }
        let booted = MockSimulator()
        given(booted).state.willReturn(.booted)
        #expect(booted.canAcceptInput)
    }

    // MARK: - chrome lookup

    @Test func `chrome looks up assets by device-type name`() {
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

        let s = MockSimulator()
        given(s).deviceTypeName.willReturn("iPhone 17 Pro")

        let result = s.chrome(in: chromes)

        #expect(result?.chrome.identifier == "phone11")
        verify(chromes).assets(forDeviceName: .value("iPhone 17 Pro")).called(1)
    }

    // Cloned simulators carry a user-given `name` (e.g. "iPhone 17 pro
    // max clone 1") that no longer matches a `.simdevicetype` bundle.
    // Chrome lookup keys off `deviceTypeName`, not the display name.
    @Test func `chrome keys off deviceTypeName even when display name differs`() {
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

        let s = MockSimulator()
        given(s).name.willReturn("iPhone 17 pro max clone 1")
        given(s).deviceTypeName.willReturn("iPhone 17 Pro Max")

        let result = s.chrome(in: chromes)

        #expect(result?.chrome.identifier == "phone11")
        verify(chromes).assets(forDeviceName: .value("iPhone 17 Pro Max")).called(1)
    }

    // MARK: - presentation

    @Test func `json shape matches the list subcommand contract`() {
        let s = MockSimulator()
        given(s).udid.willReturn("u1")
        given(s).name.willReturn("iPhone 17")
        given(s).state.willReturn(.booted)
        given(s).runtime.willReturn("iOS 26.4")

        #expect(s.json ==
            "{\"udid\":\"u1\",\"name\":\"iPhone 17\",\"state\":\"Booted\",\"runtime\":\"iOS 26.4\"}")
    }

    // The `state` strings end up in the list output and the serve UI;
    // exhaustively pin every enum case so a typo or new case is caught.
    @Test func `SimulatorState description covers all cases`() {
        #expect(SimulatorState.creating.description == "Creating")
        #expect(SimulatorState.shutdown.description == "Shutdown")
        #expect(SimulatorState.booting.description == "Booting")
        #expect(SimulatorState.booted.description == "Booted")
        #expect(SimulatorState.shuttingDown.description == "ShuttingDown")
    }
}
