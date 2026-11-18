import Testing
import Foundation
import Mockable
@testable import Baguette

/// Display planes hang off the simulator as a plural aggregate. Callers
/// pick phone or carPlay, resolve a live binding, and take screen/input
/// from that same Display so framebuffer and HID cannot cross-wire.
@Suite("Displays")
struct DisplaysTests {

    private let carPlayBinding = DisplayBinding(
        kind: .carPlay,
        connectedScreenId: 204,
        portName: "com.apple.framebuffer.display",
        size: Size(width: 800, height: 480)
    )

    @Test func `should resolve a display plane to its live binding`() throws {
        let display = MockDisplay()
        given(display).kind.willReturn(.carPlay)
        given(display).resolve().willReturn(carPlayBinding)

        let binding = try display.resolve()

        #expect(binding == carPlayBinding)
        #expect(display.kind == .carPlay)
    }

    @Test func `should take screen and input from the same display`() {
        let display = MockDisplay()
        let screen = MockScreen()
        let input = InputMocks()
        given(display).screen().willReturn(screen)
        given(display).input().willReturn(input)

        #expect(display.screen() as? MockScreen === screen)
        #expect(display.input() as? InputMocks === input)
    }

    @Test func `should look up the phone and carPlay displays by kind`() {
        let displays = MockDisplays()
        let phone = MockDisplay()
        let carPlay = MockDisplay()
        given(phone).kind.willReturn(.phone)
        given(carPlay).kind.willReturn(.carPlay)
        given(displays).phone.willReturn(phone)
        given(displays).carPlay.willReturn(carPlay)

        #expect(displays.phone.kind == .phone)
        #expect(displays.carPlay.kind == .carPlay)
        #expect(displays[.phone].kind == .phone)
        #expect(displays[.carPlay].kind == .carPlay)
        #expect(displays[.phone] as? MockDisplay === phone)
        #expect(displays[.carPlay] as? MockDisplay === carPlay)
    }

    @Test func `should offer a simulator's displays and its external displays`() {
        let sim = MockSimulator()
        let displays = MockDisplays()
        let external = MockExternalDisplays()
        given(sim).displays().willReturn(displays)
        given(sim).externalDisplays().willReturn(external)

        #expect(sim.displays() as? MockDisplays === displays)
        #expect(sim.externalDisplays() as? MockExternalDisplays === external)
    }
}

/// Host External Displays panel. enableCarPlay converges to connected;
/// a second call is a no-op against that same end state.
@Suite("ExternalDisplays")
struct ExternalDisplaysTests {

    @Test func `should stay connected when CarPlay is enabled twice`() throws {
        let external = MockExternalDisplays()
        let state = ConnectedFlag()
        given(external).isCarPlayConnected.willProduce { state.value }
        given(external).enableCarPlay().willProduce { state.value = true }

        #expect(!external.isCarPlayConnected)

        try external.enableCarPlay()
        #expect(external.isCarPlayConnected)

        try external.enableCarPlay()
        #expect(external.isCarPlayConnected)

        verify(external).enableCarPlay().called(2)
    }

    private final class ConnectedFlag: @unchecked Sendable {
        var value = false
    }
}
