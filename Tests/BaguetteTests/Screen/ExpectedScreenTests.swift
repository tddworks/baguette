import Foundation
import Testing

@testable import Baguette

@Suite("ExpectedScreen")
struct ExpectedScreenTests {
    static let json =
        #"{"width":402,"height":874,"orientation":"portrait","target":{"screenId":1,"litPanel":null,"pixelSize":{"width":1206,"height":2622}}}"#

    @Test func `parses an observed single-panel screen without inventing a panel`() throws {
        let expected = try ExpectedScreen(json: Self.json)
        #expect(expected.screen.width == 402)
        #expect(expected.screen.orientation == .portrait)
        #expect(expected.screen.target?.screenId == 1)
        #expect(expected.screen.target?.litPanel == nil)
        #expect(expected.screen.target?.pixelSize == Size(width: 1206, height: 2622))
    }

    @Test func `parses a named lit panel`() throws {
        let expected = try ExpectedScreen(
            json: Self.json.replacingOccurrences(of: "\"litPanel\":null", with: "\"litPanel\":\"secondary\""))
        #expect(expected.screen.target?.litPanel == .secondary)
    }

    @Test(arguments: [
        "{}",
        ExpectedScreenTests.json.replacingOccurrences(of: "1206", with: "0"),
        ExpectedScreenTests.json.replacingOccurrences(of: "\"width\":402", with: "\"width\":0"),
        ExpectedScreenTests.json.replacingOccurrences(of: "\"screenId\":1", with: "\"screenId\":1.5"),
        ExpectedScreenTests.json.replacingOccurrences(of: "portrait", with: "sideways"),
        ExpectedScreenTests.json.replacingOccurrences(of: "\"litPanel\":null", with: "\"litPanel\":\"guessed\""),
    ])
    func `missing identity invalid dimensions and unknown panels fail at the boundary`(json: String) {
        #expect(throws: (any Error).self) { try ExpectedScreen(json: json) }
    }

    @Test func `changed identity pixels panel orientation or points reject new input`() throws {
        let expected = try ExpectedScreen(json: Self.json)
        try expected.requireMatches(expected.screen)
        for json in [
            Self.json.replacingOccurrences(of: "\"screenId\":1", with: "\"screenId\":2"),
            Self.json.replacingOccurrences(of: "1206", with: "1209"),
            Self.json.replacingOccurrences(of: "\"litPanel\":null", with: "\"litPanel\":\"secondary\""),
            Self.json.replacingOccurrences(of: "portrait", with: "landscape-left"),
            Self.json.replacingOccurrences(of: "402", with: "403"),
        ] {
            let changed = try ExpectedScreen(json: json).screen
            #expect(throws: ExpectedScreen.Failure.changed) { try expected.requireMatches(changed) }
        }
    }

    @Test func `an envelope must name the observed native points or no size at all`() throws {
        let expected = try ExpectedScreen(json: Self.json)
        try expected.validateEnvelope(["type": "tap", "x": 10, "y": 20])
        try expected.validateEnvelope(["width": 402, "height": 874])
        #expect(throws: ExpectedScreen.Failure.coordinateSize) {
            try expected.validateEnvelope(["width": 1206, "height": 2622])
        }
    }

    @Test func `loss of a target blocks down and move but never blocks release`() throws {
        let expected = try ExpectedScreen(json: Self.json)
        let screenGuard = InputScreenGuard(expected: expected) { throw ObservedScreenError.unavailable }
        #expect(!screenGuard.allows(.down))
        #expect(!screenGuard.allows(.move))
        #expect(screenGuard.errorDescription == ObservedScreenError.unavailable.localizedDescription)
        #expect(screenGuard.allows(.up))
    }

    @Test func `release never probes again after a move observes a different target`() throws {
        let expected = try ExpectedScreen(json: Self.json)
        var reads = 0
        let screenGuard = InputScreenGuard(expected: expected) {
            reads += 1
            if reads == 1 { return expected.screen }
            return try ExpectedScreen(json: Self.json.replacingOccurrences(of: "1206", with: "1209")).screen
        }
        #expect(screenGuard.allows(.down))
        #expect(screenGuard.errorDescription == nil)
        #expect(!screenGuard.allows(.move))
        #expect(screenGuard.errorDescription == ExpectedScreen.Failure.changed.localizedDescription)
        #expect(screenGuard.allows(.up))
        #expect(reads == 2)
    }
}
