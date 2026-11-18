import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// `AXHitTestGrid` is the pure point-generator that lets the AX
/// adapter recover elements the frontmost-app walk can't reach:
/// SpringBoard's status bar (clock / Wi-Fi / battery — a different
/// process) and SwiftUI containers that report empty children but
/// answer positional hit-tests (tab bars, nav bars, toolbars).
@Suite("AXHitTestGrid")
struct AXHitTestGridTests {

    @Test func `should probe a step-spaced grid across the screen`() {
        let grid = AXHitTestGrid(size: Size(width: 100, height: 100), step: 50, cap: 600)
        // Cell-centred samples at 25 and 75 on each axis → 2×2.
        let pts = grid.samplePoints()
        #expect(pts.contains(Point(x: 25, y: 25)))
        #expect(pts.contains(Point(x: 75, y: 25)))
        #expect(pts.contains(Point(x: 25, y: 75)))
        #expect(pts.contains(Point(x: 75, y: 75)))
        #expect(pts.count == 4)
    }

    @Test func `should probe the top strip first so the status bar is found early`() {
        let grid = AXHitTestGrid(size: Size(width: 100, height: 400), step: 50, cap: 600)
        let pts = grid.samplePoints()
        // Row-major from the top: the first point is in the top strip
        // where SpringBoard's status bar lives.
        #expect(pts.first?.y == 25)
    }

    @Test func `should probe a single row across the width when the screen is a thin band`() {
        // Status-bar-band usage: a short grid produces one row of
        // probe points spanning the screen width.
        let band = AXHitTestGrid(size: Size(width: 440, height: 40), step: 32, cap: 600)
        let pts = band.samplePoints()
        #expect(pts.allSatisfy { $0.y == 16 })
        #expect(pts.count == 14)   // 16, 48, …, 432
    }

    @Test func `should skip probes inside an element already fully described`() {
        let grid = AXHitTestGrid(size: Size(width: 100, height: 100), step: 50, cap: 600)
        // A leaf covering the whole top-left cell (contains 25,25).
        let leaf = Rect(origin: Point(x: 0, y: 0), size: Size(width: 50, height: 50))
        let pts = grid.samplePoints(covered: [leaf])
        #expect(!pts.contains(Point(x: 25, y: 25)))
        #expect(pts.contains(Point(x: 75, y: 25)))
        #expect(pts.count == 3)
    }

    @Test func `should cap the number of probes`() {
        let grid = AXHitTestGrid(size: Size(width: 1000, height: 1000), step: 10, cap: 5)
        #expect(grid.samplePoints().count == 5)
    }

    @Test func `should probe nothing when the screen has zero size`() {
        let grid = AXHitTestGrid(size: Size(width: 0, height: 0), step: 32, cap: 600)
        #expect(grid.samplePoints().isEmpty)
    }
}
