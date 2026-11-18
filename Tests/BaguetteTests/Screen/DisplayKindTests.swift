import Testing
@testable import Baguette
@testable import BaguetteDevice

/// Wire / CLI tokens map onto display kinds. Unknown tokens stay nil so
/// App can default to phone without Domain inventing a fallback.
@Suite("DisplayKind")
struct DisplayKindTests {

    @Test func `should read phone from the display query in any case`() {
        #expect(DisplayKind.parse(query: "phone") == .phone)
        #expect(DisplayKind.parse(query: "PHONE") == .phone)
        #expect(DisplayKind.parse(query: "Phone") == .phone)
    }

    @Test func `should read carplay from the display query in any case`() {
        #expect(DisplayKind.parse(query: "carplay") == .carPlay)
        #expect(DisplayKind.parse(query: "CarPlay") == .carPlay)
        #expect(DisplayKind.parse(query: "CARPLAY") == .carPlay)
    }

    @Test func `should reject an unknown, empty or missing display query`() {
        #expect(DisplayKind.parse(query: "tv") == nil)
        #expect(DisplayKind.parse(query: "") == nil)
        #expect(DisplayKind.parse(query: nil) == nil)
    }

    @Test func `should read phone and carplay from the --display flag and reject anything else`() {
        #expect(DisplayKind.parse(cliFlag: "phone") == .phone)
        #expect(DisplayKind.parse(cliFlag: "carplay") == .carPlay)
        #expect(DisplayKind.parse(cliFlag: "CARPLAY") == .carPlay)
        #expect(DisplayKind.parse(cliFlag: "external") == nil)
        #expect(DisplayKind.parse(cliFlag: nil) == nil)
    }
}
