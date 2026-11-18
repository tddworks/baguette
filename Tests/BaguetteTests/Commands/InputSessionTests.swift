import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// `baguette input`: one stdin line in, one answer out — each line routed
/// to whichever of the session's roles it is for.
@Suite("Input session")
struct InputSessionTests {

    private func session(
        _ input: InputMocks, accessibility: any Accessibility = MockAccessibility()
    ) -> InputSession {
        InputSession(
            input: input.abilities, pasteboard: MockPasteboard(), accessibility: accessibility,
            screenGuard: nil, inputTaken: { false })
    }

    @Test func `should answer a gesture line with whether it landed`() async {
        let input = InputMocks()
        given(input.touch).tap(at: .any, size: .any, duration: .any, edge: .any).willReturn(true)

        let answer = await session(input).answer(#"{"type":"tap","x":1,"y":2,"width":100,"height":200}"#)

        #expect(answer == #"{"ok":true}"#)
    }

    @Test func `should answer a line it can't read with why`() async {
        let answer = await session(InputMocks()).answer("not json")

        #expect(answer.hasPrefix(#"{"ok":false"#))
    }

    @Test func `should answer a describe line in the device's own words when it can't read its screen`() async {
        let device = commandDevice(name: "han's iPhone")
        let accessibility = InputSession.accessibility(of: device)

        let answer = await session(InputMocks(), accessibility: accessibility)
            .answer(#"{"type":"describe_ui"}"#)

        #expect(answer.contains(#""type":"describe_ui_result","ok":false"#))
        #expect(answer.contains("han's iPhone"))
    }

    @Test func `should read the screen with the device's own accessibility when it has one`() {
        let accessibility = MockAccessibility()
        let device = commandDevice { $0.register(.accessibility) { accessibility } }

        #expect(InputSession.accessibility(of: device) as AnyObject === accessibility)
    }
}
