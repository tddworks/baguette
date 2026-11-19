import Foundation
import Testing

@testable import Baguette
@testable import BaguetteDevice

@Suite("ScreenTarget")
struct ScreenTargetTests {
    @Test(arguments: [
        (IntegratedPanel?.none, "null"),
        (IntegratedPanel.primary, "primary"),
        (IntegratedPanel.secondary, "secondary"),
    ])
    func `should name the lit panel on the wire or send null when there is none`(panel: IntegratedPanel?, wire: String) throws {
        let target = ScreenTarget(screenId: 7, litPanel: panel, pixelSize: Size(width: 1206, height: 2622))
        let json = try JSONSerialization.data(withJSONObject: target.dictionary, options: .sortedKeys)
        #expect(
            String(decoding: json, as: UTF8.self)
                == #"{"litPanel":\#(wire == "null" ? "null" : "\"\(wire)\""),"pixelSize":{"height":2622,"width":1206},"screenId":7}"#)
    }

    @Test func `should explain that the display cannot provide a fresh screen target`() {
        #expect(ObservedScreenError.unavailable.localizedDescription == "the display cannot provide a fresh screen target")
    }

    @Test func `should refuse instead of guessing a panel when a display cannot be observed`() {
        struct Unobservable: Display {
            var kind: DisplayKind { .phone }
            func resolve() throws -> DisplayBinding { throw ObservedScreenError.unavailable }
            func screen() -> any Screen { MockScreen() }
            func input() -> any HID { InputMocks() }
        }
        #expect(throws: ObservedScreenError.unavailable) { try Unobservable().observedScreen() }
    }
}
