import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// A display plan bound to any device — a simulator's planes, or a
/// physical phone that has only its own screen.
@Suite("StreamDisplayPlan on a device")
struct StreamDisplayPlanDeviceTests {
    @Test func `should enable CarPlay once when binding a device's screen and input together`() throws {
        let carPlay = MockDisplay()
        given(carPlay).resolve().willReturn(DisplayBinding(
            kind: .carPlay, connectedScreenId: 2,
            portName: "com.apple.framebuffer.display", size: Size(width: 800, height: 480)))
        given(carPlay).screen().willReturn(MockScreen())
        given(carPlay).input().willReturn(InputMocks())
        let displays = MockDisplays()
        given(displays).carPlay.willReturn(carPlay)
        let external = MockExternalDisplays()
        given(external).enableCarPlay().willReturn()
        var abilities = Abilities(device: "iPhone 17 Pro")
        abilities.register(.displays) { displays }
        abilities.register(.externalDisplays) { external }

        let bound = try StreamDisplayPlan(kind: .carPlay, enableCarPlay: true).bind(to: device(abilities))

        _ = try #require(bound.input).require(.touch)
        verify(external).enableCarPlay().called(1)
    }

    @Test func `should stream a device that shows a screen but takes no touches, with no input`() throws {
        var abilities = Abilities(device: "han's iPhone")
        abilities.register(.screen) { MockScreen() }

        let bound = try StreamDisplayPlan.phoneOnly.bind(to: device(abilities))

        #expect(bound.input == nil)
    }

    @Test func `should show a device's own screen when the plan is the phone plane`() throws {
        let screen = MockScreen()
        var abilities = Abilities(device: "han's iPhone")
        abilities.register(.screen) { screen }

        let shown = try StreamDisplayPlan.phoneOnly.screen(on: device(abilities))

        #expect(shown as AnyObject === screen)
    }

    @Test func `should show a pinned panel's screen from the device's displays`() throws {
        let screen = MockScreen()
        let cover = MockDisplay()
        given(cover).screen().willReturn(screen)
        let displays = MockDisplays()
        given(displays).panel(.value(.secondary)).willReturn(cover)
        var abilities = Abilities(device: "iPhone Duo")
        abilities.register(.displays) { displays }

        let plan = StreamDisplayPlan(kind: .phone, enableCarPlay: false, panel: .secondary)
        let shown = try plan.screen(on: device(abilities))

        #expect(shown as AnyObject === screen)
    }

    @Test func `should enable CarPlay before showing its screen when the plan says so`() throws {
        let screen = MockScreen()
        let carPlay = MockDisplay()
        given(carPlay).resolve().willReturn(DisplayBinding(
            kind: .carPlay, connectedScreenId: 2,
            portName: "com.apple.framebuffer.display", size: Size(width: 800, height: 480)))
        given(carPlay).screen().willReturn(screen)
        let displays = MockDisplays()
        given(displays).carPlay.willReturn(carPlay)
        let external = MockExternalDisplays()
        given(external).enableCarPlay().willReturn()
        var abilities = Abilities(device: "iPhone 17 Pro")
        abilities.register(.displays) { displays }
        abilities.register(.externalDisplays) { external }

        let shown = try StreamDisplayPlan(kind: .carPlay, enableCarPlay: true).screen(on: device(abilities))

        #expect(shown as AnyObject === screen)
        verify(external).enableCarPlay().called(1)
    }

    @Test func `should refuse the CarPlay plane on a device that has no display planes`() {
        let phone = device(Abilities(device: "han's iPhone"))

        #expect(throws: DeviceError.unable(ability: "displays", device: "han's iPhone")) {
            try StreamDisplayPlan(kind: .carPlay, enableCarPlay: false).screen(on: phone)
        }
    }

    @Test func `should touch a device's own screen when the plan is the phone plane`() throws {
        let touch = MockTouch()
        var abilities = Abilities(device: "iPhone 17 Pro")
        abilities.register(.touch) { touch }

        let touched = try StreamDisplayPlan.phoneOnly.input(on: device(abilities))

        #expect(try touched.require(.touch) as AnyObject === touch)
    }

    @Test func `should refuse to touch a phone that registered no touch`() {
        var abilities = Abilities(device: "han's iPhone")
        abilities.register(.screen) { MockScreen() }

        #expect(throws: DeviceError.unable(ability: "touch", device: "han's iPhone")) {
            try StreamDisplayPlan.phoneOnly.input(on: device(abilities))
        }
    }

    private func device(_ abilities: Abilities) -> MockDevice {
        let device = MockDevice()
        given(device).name.willReturn("device")
        given(device).state.willReturn(.ready)
        given(device).abilities.willReturn(abilities)
        return device
    }
}
