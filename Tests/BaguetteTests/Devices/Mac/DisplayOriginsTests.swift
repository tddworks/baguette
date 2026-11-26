import Testing
@testable import Baguette
@testable import BaguetteDeviceFamilies
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

    // The desktop measured while a share was main: the share (44) at the left,
    // the UP2516D (3) right beside it — so a Dock on the right never came up on
    // the share; the pointer crossed into the UP2516D instead.
    static let desktop: [UInt32: Rect] = [
        44: Rect(origin: Point(x: 0, y: 0), size: Size(width: 660, height: 1149)),
        3: Rect(origin: Point(x: 660, y: 0), size: Size(width: 1440, height: 2560)),
        2: Rect(origin: Point(x: 2100, y: 595), size: Size(width: 2560, height: 1440)),
    ]

    @Test func `should place a display made main at the right end, top-aligned, when the Dock is on the right`() {
        let placed = DisplayOrigins.makingMain(44, in: Self.desktop, freeing: .right)
        #expect(placed == [44: Point(x: 0, y: 0), 3: Point(x: -4000, y: 0), 2: Point(x: -2560, y: 595)])
    }

    @Test func `should place a display made main at the right end when the Dock is at the bottom, nothing below it`() {
        #expect(DisplayOrigins.makingMain(44, in: Self.desktop, freeing: .bottom)
            == DisplayOrigins.makingMain(44, in: Self.desktop, freeing: .right))
    }

    @Test func `should place a display made main at the left end, top-aligned, when the Dock is on the left`() {
        let placed = DisplayOrigins.makingMain(2, in: Self.desktop, freeing: .left)
        #expect(placed == [2: Point(x: 0, y: 0), 44: Point(x: 2560, y: 0), 3: Point(x: 3220, y: 0)])
    }

    @Test func `should keep the arrangement as it is when it only shifts, freeing nothing`() {
        let shifted = DisplayOrigins.makingMain(3, in: Self.desktop, freeing: nil)
        #expect(shifted == [44: Point(x: -660, y: 0), 3: Point(x: 0, y: 0), 2: Point(x: 1440, y: 595)])
    }

    @Test func `should read which side the Dock is on as macOS stores it, the bottom when it says nothing`() {
        #expect(DockEdge(orientation: "right") == .right)
        #expect(DockEdge(orientation: "left") == .left)
        #expect(DockEdge(orientation: "bottom") == .bottom)
        #expect(DockEdge(orientation: nil) == .bottom)
    }
}
