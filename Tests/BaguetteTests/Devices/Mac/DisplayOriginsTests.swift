import Testing
@testable import Baguette
@testable import BaguetteDevice

/// Where every display sits once one of them is made main: the main display is
/// the one at the desktop's origin, so the whole arrangement shifts, keeping
/// each display where it is beside the others.
@Suite("DisplayOrigins")
struct DisplayOriginsTests {
    @Test func `should shift every display so the chosen one is at the origin`() {
        let now: [UInt32: Point] = [
            1: Point(x: 0, y: 0), 2: Point(x: 1440, y: 595), 5: Point(x: -603, y: 0),
        ]
        #expect(DisplayOrigins.makingMain(5, in: now) == [
            1: Point(x: 603, y: 0), 2: Point(x: 2043, y: 595), 5: Point(x: 0, y: 0),
        ])
    }

    @Test func `should move nothing when the chosen display is not among them`() {
        let now: [UInt32: Point] = [1: Point(x: 0, y: 0)]
        #expect(DisplayOrigins.makingMain(9, in: now) == nil)
    }
}
