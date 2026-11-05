import Testing
import Foundation
@testable import Baguette

/// An agent knows it wants `Search flights`. Finding that element, and a
/// point on it the app will respond to, is baguette's job rather than the
/// agent's.
@Suite("AXTarget")
struct AXTargetTests {
    private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> Rect {
        Rect(origin: Point(x: x, y: y), size: Size(width: width, height: height))
    }

    private func button(_ label: String, _ frame: Rect, id: String? = nil, enabled: Bool = true) -> AXNode {
        AXNode(role: "AXButton", label: label, identifier: id, frame: frame, enabled: enabled)
    }

    private func app(_ children: AXNode...) -> AXNode {
        AXNode(
            role: "AXApplication", label: "Skylark", frame: rect(0, 0, 402, 874), children: children,
            screen: AXScreen(width: 402, height: 874, orientation: .portrait))
    }

    private func point(_ lookup: AXTarget.Lookup) -> Point? {
        if case .tap(_, let point) = lookup { return point }
        return nil
    }

    @Test func `should find an element by its exact label and tap its centre`() {
        let lookup = AXTarget.find("Search flights", in: app(button("Search flights", rect(28, 421, 346, 58))))

        #expect(point(lookup) == Point(x: 201, y: 450))
    }

    @Test func `should find an element by its identifier`() {
        let lookup = AXTarget.find("BackButton", in: app(button("Settings", rect(16, 62, 44, 44), id: "BackButton")))

        #expect(point(lookup) == Point(x: 38, y: 84))
    }

    @Test func `should find an element by part of its label when only one matches`() {
        let lookup = AXTarget.find("haneda", in: app(
            button("Tokyo Haneda (HND)", rect(16, 325, 370, 52)), button("Tokyo Narita (NRT)", rect(16, 377, 370, 52))))

        #expect(point(lookup) == Point(x: 201, y: 351))
    }

    @Test func `should prefer an exact match over a partial one`() {
        let lookup = AXTarget.find("Home", in: app(
            button("Home", rect(0, 0, 40, 40)), button("Home Screen & App Library", rect(0, 100, 40, 40))))

        #expect(point(lookup) == Point(x: 20, y: 20))
    }

    @Test func `should not guess between elements that match equally`() {
        let tokyo = button("Tokyo Haneda (HND)", rect(16, 325, 370, 52))
        let narita = button("Tokyo Narita (NRT)", rect(16, 377, 370, 52))

        #expect(AXTarget.find("Tokyo", in: app(tokyo, narita)) == .ambiguous([tokyo, narita]))
    }

    @Test func `should prefer a control over text with the same label`() {
        let lookup = AXTarget.find("Saved", in: app(
            AXNode(role: "AXStaticText", label: "Saved", frame: rect(0, 0, 40, 40)),
            button("Saved", rect(0, 100, 40, 40))))

        #expect(point(lookup) == Point(x: 20, y: 120))
    }

    @Test func `should tap plain text when text is all there is`() {
        let lookup = AXTarget.find("See all", in: app(AXNode(role: "AXStaticText", label: "See all", frame: rect(336, 505, 50, 20))))

        #expect(point(lookup) == Point(x: 361, y: 515))
    }

    @Test func `should choose the element itself over a container with the same label`() {
        let inner = button("Pay", rect(10, 10, 40, 40))
        let lookup = AXTarget.find("Pay", in: app(
            AXNode(role: "AXGroup", label: "Pay", frame: rect(0, 0, 200, 200), children: [inner])))

        #expect(point(lookup) == Point(x: 30, y: 30))
    }

    @Test func `should not match the app itself`() {
        #expect(AXTarget.find("Skylark", in: app()) == .missing)
    }

    @Test func `should report an element that is disabled`() {
        let pay = button("Pay $1,240", rect(16, 717, 370, 58), enabled: false)

        #expect(AXTarget.find("Pay", in: app(pay)) == .disabled(pay))
    }

    @Test func `should report an element that is off screen`() {
        let seat = button("Seat 20A", rect(48, 1000, 46, 40))

        #expect(AXTarget.find("Seat 20A", in: app(seat)) == .offScreen(seat))
    }

    @Test func `should ignore a page that has slid off the side when the same name is on screen`() {
        let old = button("Continue", rect(-105, 700, 40, 40))
        let current = button("Continue", rect(100, 700, 40, 40))

        #expect(point(AXTarget.find("Continue", in: app(old, current))) == Point(x: 120, y: 720))
    }

    @Test func `should tap the visible part of an element hanging off the screen`() {
        let lookup = AXTarget.find("Smart Invert", in: app(button("Smart Invert", rect(36, 860, 100, 28))))

        #expect(point(lookup) == Point(x: 86, y: 867))
    }

    @Test func `should tap near the left of a wide row whose label has several parts`() {
        let lookup = AXTarget.find("Orbit 3", in: app(button("Orbit 3, 10h 10m, $1,240", rect(16, 514, 370, 73))))

        #expect(point(lookup) == Point(x: 56, y: 550.5))
    }

    @Test func `should tap the centre of a narrow element whose label has several parts`() {
        let lookup = AXTarget.find("Paris", in: app(button("Paris, France", rect(0, 0, 100, 40))))

        #expect(point(lookup) == Point(x: 50, y: 20))
    }

    @Test func `should report an element a floating bar sits over`() {
        let seat = button("Seat 15A", rect(48, 796, 46, 40))
        let tabBar = AXNode(role: "AXGroup", label: "Tab Bar", frame: rect(0, 791, 402, 83))

        #expect(AXTarget.find("Seat 15A", in: app(seat, tabBar)) == .covered(seat))
    }

    @Test func `should tap a control in the bar that covers others`() {
        let seat = button("Seat 15A", rect(48, 796, 46, 40))
        let tabBar = AXNode(
            role: "AXGroup", label: "Tab Bar", frame: rect(0, 791, 402, 83),
            children: [AXNode(role: "AXRadioButton", label: "Trips", frame: rect(110, 795, 98, 54))])

        #expect(point(AXTarget.find("Trips", in: app(seat, tabBar))) == Point(x: 159, y: 822))
    }

    @Test func `should say nothing matches when nothing does`() {
        #expect(AXTarget.find("Nope", in: app(button("Pay", rect(0, 0, 40, 40)))) == .missing)
    }

    @Test func `should list what is on screen so the caller can correct a wrong name`() {
        let tree = app(
            button("Pay", rect(0, 0, 40, 40)),
            AXNode(role: "AXGroup", frame: rect(0, 0, 402, 874)),
            button("Below", rect(0, 900, 40, 40)))

        #expect(AXTarget.visibleNames(in: tree) == ["Pay"])
    }
}

@Suite("AXTarget waiting")
struct AXTargetWaitTests {
    private static let frame = Rect(origin: Point(x: 0, y: 0), size: Size(width: 40, height: 40))
    private static let screen = AXScreen(width: 402, height: 874, orientation: .portrait)

    private func tree(_ children: AXNode...) -> AXNode {
        AXNode(role: "AXApplication", frame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 402, height: 874)), children: children, screen: Self.screen)
    }

    private func pay(enabled: Bool = true) -> AXNode { AXNode(role: "AXButton", label: "Pay", frame: Self.frame, enabled: enabled) }

    private func run(glances: [AXNode?], reads: [AXNode?] = [nil]) -> (AXTarget.Found, TimeInterval, Int) {
        var g = glances, r = reads, time: TimeInterval = 0, fullReads = 0
        let found = AXTarget.wait(
            for: "Pay",
            glance: { g.count > 1 ? g.removeFirst() : g.first ?? nil },
            read: { fullReads += 1; return r.count > 1 ? r.removeFirst() : r.first ?? nil },
            timeout: 1, poll: 0.1, now: { time }, sleep: { time += $0 })
        return (found, time, fullReads)
    }

    @Test func `should tap at once from a cheap look when the element is there`() {
        let (found, time, fullReads) = run(glances: [tree(pay())])

        #expect(found.lookup == .tap(pay(), Point(x: 20, y: 20)))
        #expect(found.screen == Self.screen)
        #expect(time == 0)
        #expect(fullReads == 0)
    }

    @Test func `should take a full look for what only the sweep finds`() {
        let (found, _, fullReads) = run(glances: [tree()], reads: [tree(pay())])

        #expect(found.lookup == .tap(pay(), Point(x: 20, y: 20)))
        #expect(fullReads == 1)
    }

    @Test func `should wait for an element that has not appeared yet`() {
        let (found, time, _) = run(glances: [tree(), tree(), tree(pay())])

        #expect(found.lookup == .tap(pay(), Point(x: 20, y: 20)))
        #expect(time > 0)
        #expect(time < 1)
    }

    @Test func `should wait for a disabled element to become enabled`() {
        let (found, _, _) = run(glances: [tree(pay(enabled: false)), tree(pay())])

        #expect(found.lookup == .tap(pay(), Point(x: 20, y: 20)))
    }

    @Test func `should give up and report the last thing it saw`() {
        let (found, time, _) = run(glances: [tree(pay(enabled: false))], reads: [tree(pay(enabled: false))])

        #expect(found.lookup == .disabled(pay(enabled: false)))
        #expect(time >= 1)
    }
}
