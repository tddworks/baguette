import Foundation
import Testing

@testable import Baguette

@Suite("ScreenTarget")
struct ScreenTargetTests {
    @Test(arguments: [
        (IntegratedPanel?.none, "null"),
        (IntegratedPanel.primary, "primary"),
        (IntegratedPanel.secondary, "secondary"),
    ])
    func `the wire names the lit panel or says there is none`(panel: IntegratedPanel?, wire: String) throws {
        let target = ScreenTarget(screenId: 7, litPanel: panel, pixelSize: Size(width: 1206, height: 2622))
        let json = try JSONSerialization.data(withJSONObject: target.dictionary, options: .sortedKeys)
        #expect(
            String(decoding: json, as: UTF8.self)
                == #"{"litPanel":\#(wire == "null" ? "null" : "\"\(wire)\""),"pixelSize":{"height":2622,"width":1206},"screenId":7}"#)
    }

    @Test func `an unobservable display names the failure`() {
        #expect(ObservedScreenError.unavailable.localizedDescription == "the display cannot provide a fresh screen target")
    }

    @Test func `a display without an observation fails closed instead of guessing a panel`() {
        struct Unobservable: Display {
            var kind: DisplayKind { .phone }
            func resolve() throws -> DisplayBinding { throw ObservedScreenError.unavailable }
            func screen() -> any Screen { MockScreen() }
            func input() -> any Input { MockInput() }
        }
        #expect(throws: ObservedScreenError.unavailable) { try Unobservable().observedScreen() }
    }
}
