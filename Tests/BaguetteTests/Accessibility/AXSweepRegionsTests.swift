import Testing
import Foundation
import CoreGraphics
@testable import Baguette

/// The sweep probes only where the walk couldn't see: inside childless
/// containers and along the status bar. Everywhere else the walk already
/// described what is there, so a probe only costs an XPC round-trip.
@Suite("Hit-test sweep regions")
struct AXSweepRegionsTests {
    private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> Rect {
        Rect(origin: Point(x: x, y: y), size: Size(width: width, height: height))
    }

    @Test func `should probe a childless container even when a leaf lies beneath it`() {
        let tabBar = rect(0, 791, 402, 83)
        let tree = AXNode(
            role: "AXApplication", frame: rect(0, 0, 402, 874),
            children: [
                AXNode(role: "AXStaticText", label: "Row 8", frame: rect(16, 792, 370, 52)),
                AXNode(role: "AXGroup", label: "Tab Bar", frame: tabBar),
            ])

        #expect(tree.unseenRegions() == [tabBar])
    }

    @Test func `should not probe around elements the walk fully described`() {
        let tree = AXNode(
            role: "AXApplication", frame: rect(0, 0, 402, 874),
            children: [
                AXNode(
                    role: "AXGroup", frame: rect(0, 0, 402, 874),
                    children: [AXNode(role: "AXButton", label: "General", frame: rect(16, 293, 370, 52))]),
            ])

        #expect(tree.unseenRegions().isEmpty)
    }

    @Test func `should probe the whole screen when the walk found nothing`() {
        let root = rect(0, 0, 402, 874)

        #expect(AXNode(role: "AXApplication", frame: root).unseenRegions() == [root])
    }

    @Test func `should find childless containers at any depth`() {
        let toolbar = rect(0, 0, 402, 83)
        let tree = AXNode(
            role: "AXApplication", frame: rect(0, 0, 402, 874),
            children: [AXNode(role: "AXGroup", frame: rect(0, 0, 402, 200), children: [AXNode(role: "AXGroup", frame: toolbar)])])

        #expect(tree.unseenRegions() == [toolbar])
    }

    @Test func `should not probe a childless container with no area`() {
        let tree = AXNode(
            role: "AXApplication", frame: rect(0, 0, 402, 874),
            children: [AXNode(role: "AXGenericElement", frame: rect(201, 270, 0, 0))])

        #expect(tree.unseenRegions().isEmpty)
    }

    @Test func `should probe only inside the given regions, on the same grid`() {
        let grid = AXHitTestGrid(size: Size(width: 100, height: 100), step: 50, cap: 600)

        #expect(grid.samplePoints(within: [rect(0, 50, 50, 50)]) == [Point(x: 25, y: 75)])
    }

    @Test func `should probe each point once when regions overlap`() {
        let grid = AXHitTestGrid(size: Size(width: 100, height: 100), step: 50, cap: 600)

        #expect(grid.samplePoints(within: [rect(0, 0, 100, 100), rect(0, 0, 50, 50)]).count == 4)
    }

    @Test func `should probe nothing when no region needs it`() {
        let grid = AXHitTestGrid(size: Size(width: 100, height: 100), step: 50, cap: 600)

        #expect(grid.samplePoints(within: []).isEmpty)
    }

    @Test func `should cap the probes in regions too`() {
        let grid = AXHitTestGrid(size: Size(width: 100, height: 100), step: 10, cap: 3)

        #expect(grid.samplePoints(within: [rect(0, 0, 100, 100)]).count == 3)
    }

    @Test(arguments: [
        (DeviceOrientation.portrait, CGRect(x: 0, y: 0, width: 402, height: 64)),
        (DeviceOrientation.portraitUpsideDown, CGRect(x: 0, y: 810, width: 402, height: 64)),
        (DeviceOrientation.landscapeLeft, CGRect(x: 0, y: 0, width: 64, height: 874)),
        (DeviceOrientation.landscapeRight, CGRect(x: 338, y: 0, width: 64, height: 874)),
    ])
    func `should find the strip along the top of the interface in every orientation`(
        orientation: DeviceOrientation, strip: CGRect
    ) {
        let transform = AXFrameTransform(pointSize: CGSize(width: 402, height: 874), orientation: orientation)

        #expect(transform.topStrip(height: 64) == strip)
    }
}

/// What the walk can't see isn't only childless containers: web content
/// lives in another process and is absent from the walk altogether. So the
/// gaps get a coarse look, and a full one only when that look finds
/// something the walk didn't know.
@Suite("AXSweep")
struct AXSweepTests {
    private static let screen = Size(width: 400, height: 400)

    private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> Rect {
        Rect(origin: Point(x: x, y: y), size: Size(width: width, height: height))
    }

    private func sweep(
        base: AXNode, probe: (Point) -> AXNode?, keepGoing: () -> Bool = { true }
    ) -> AXSweep.Result {
        AXSweep.run(
            base: base,
            fine: AXHitTestGrid(size: Self.screen, step: 50, cap: 600),
            scout: AXHitTestGrid(size: Self.screen, step: 100, cap: 600),
            statusStrip: rect(0, 0, 400, 50),
            keepGoing: keepGoing,
            probe: probe)
    }

    /// A described app whose one button sits low on the screen.
    private var described: AXNode {
        AXNode(
            role: "AXApplication", label: "App", frame: rect(0, 0, 400, 400),
            children: [AXNode(role: "AXButton", label: "Known", frame: rect(0, 300, 400, 100))])
    }

    @Test func `should scout the gaps coarsely when the walk described the screen`() {
        var probes: [Point] = []
        let result = sweep(base: described) { probes.append($0); return nil }

        let strip = (0..<8).map { Point(x: 25 + Double($0) * 50, y: 25) }
        #expect(Array(probes.prefix(8)) == strip)
        // Scouts at y 50, 150 and 250; none inside the button.
        #expect(probes.dropFirst(8).allSatisfy { Int($0.x) % 100 == 50 })
        #expect(result.probed == probes.count)
        #expect(probes.count < 16 + 8)
    }

    @Test func `should leave the gaps unswept when scouts find only what the walk knows`() {
        var probes = 0
        let known = AXNode(role: "AXButton", label: "Known", frame: rect(0, 300, 400, 100))
        let result = sweep(base: described) { _ in probes += 1; return known }

        #expect(probes == 8 + 12)
        #expect(result.probed == probes)
    }

    @Test func `should ignore a bare container a scout lands on`() {
        var probes = 0
        let bare = AXNode(role: "AXGroup", frame: rect(0, 0, 400, 400))
        _ = sweep(base: described) { _ in probes += 1; return bare }

        #expect(probes == 8 + 12)
    }

    @Test func `should sweep the gaps in full when a scout finds web content the walk missed`() {
        let text = AXNode(role: "AXStaticText", label: "From the web", frame: rect(100, 100, 100, 100))
        let link = AXNode(role: "AXLink", label: "Learn more", frame: rect(10, 260, 30, 30))
        var points: [Point] = []
        let result = sweep(base: described) { point in
            points.append(point)
            if point.y == 150 { return text }
            if point.y == 275 && point.x == 25 { return link }
            return nil
        }

        #expect(result.discovered.contains(text))
        #expect(result.discovered.contains(link))
        #expect(points.contains(Point(x: 25, y: 275)))
    }

    @Test func `should not probe the same fine point twice`() {
        let text = AXNode(role: "AXStaticText", label: "Web", frame: rect(100, 100, 100, 100))
        var points: [Point] = []
        _ = sweep(base: described) { point in
            points.append(point)
            return point.y == 150 ? text : nil
        }

        let fine = points.filter { Int($0.y) % 50 == 25 }
        #expect(Set(fine.map { "\($0.x),\($0.y)" }).count == fine.count)
    }

    @Test func `should stop when the budget runs out`() {
        var probes = 0
        let result = sweep(base: described, probe: { _ in probes += 1; return nil }, keepGoing: { probes < 3 })

        #expect(probes == 3)
        #expect(result.probed == 3)
    }

    @Test func `should probe everywhere when the walk found nothing`() {
        var probes = 0
        let empty = AXNode(role: "AXApplication", frame: rect(0, 0, 400, 400))
        _ = sweep(base: empty) { _ in probes += 1; return nil }

        #expect(probes == 64)
    }

    @Test func `should look inside a childless container even with a leaf beneath it`() {
        let base = AXNode(
            role: "AXApplication", frame: rect(0, 0, 400, 400),
            children: [
                AXNode(role: "AXStaticText", label: "Row", frame: rect(0, 300, 400, 100)),
                AXNode(role: "AXGroup", label: "Tab Bar", frame: rect(0, 300, 400, 100)),
            ])
        var points: [Point] = []
        _ = sweep(base: base) { points.append($0); return nil }

        #expect(points.contains(Point(x: 25, y: 325)))
    }
}
