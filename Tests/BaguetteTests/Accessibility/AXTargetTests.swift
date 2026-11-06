import Testing
import Foundation
@testable import Baguette

/// An agent knows it wants `Search flights`. Finding the element it means, without
/// guessing between several, is baguette's job.
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

    @Test func `should find an element by its exact label`() {
        let search = button("Search flights", rect(28, 421, 346, 58))

        #expect(AXTarget.find("Search flights", in: app(search)) == .found(search))
    }

    @Test func `should find an element by its identifier`() {
        let back = button("Settings", rect(16, 62, 44, 44), id: "BackButton")

        #expect(AXTarget.find("BackButton", in: app(back)) == .found(back))
    }

    @Test func `should find an element by part of its label when only one matches`() {
        let haneda = button("Tokyo Haneda (HND)", rect(16, 325, 370, 52))

        #expect(AXTarget.find("haneda", in: app(haneda, button("Tokyo Narita (NRT)", rect(16, 377, 370, 52)))) == .found(haneda))
    }

    @Test func `should prefer an exact match over a partial one`() {
        let home = button("Home", rect(0, 0, 40, 40))

        #expect(AXTarget.find("Home", in: app(home, button("Home Screen & App Library", rect(0, 100, 40, 40)))) == .found(home))
    }

    @Test func `should not guess between elements that match equally`() {
        let tokyo = button("Tokyo Haneda (HND)", rect(16, 325, 370, 52))
        let narita = button("Tokyo Narita (NRT)", rect(16, 377, 370, 52))

        #expect(AXTarget.find("Tokyo", in: app(tokyo, narita)) == .ambiguous([tokyo, narita]))
    }

    @Test func `should reach each of several controls that share a name by its number`() {
        let first = button("Maps", rect(0, 0, 40, 40))
        let second = button("Maps", rect(0, 100, 40, 40))
        let tree = app(first, second)

        #expect(AXTarget.find("Maps #1", in: tree) == .found(first))
        #expect(AXTarget.find("Maps #2", in: tree) == .found(second))
        #expect(AXTarget.find("Maps", in: tree) == .ambiguous([first, second]))
        #expect(AXTarget.find("Maps #3", in: tree) == .missing)
    }

    @Test func `should reach a control with no name by the role it's listed under`() {
        let bare = AXNode(role: "AXButton", frame: rect(0, 0, 40, 40))

        #expect(AXTarget.find("Button", in: app(bare)) == .found(bare))
    }

    @Test func `should prefer a control over text with the same label`() {
        let saved = button("Saved", rect(0, 100, 40, 40))

        #expect(AXTarget.find("Saved", in: app(AXNode(role: "AXStaticText", label: "Saved", frame: rect(0, 0, 40, 40)), saved)) == .found(saved))
    }

    @Test func `should find plain text when text is all there is`() {
        let text = AXNode(role: "AXStaticText", label: "See all", frame: rect(336, 505, 50, 20))

        #expect(AXTarget.find("See all", in: app(text)) == .found(text))
    }

    @Test func `should choose the element itself over a container with the same label`() {
        let inner = button("Pay", rect(10, 10, 40, 40))

        #expect(AXTarget.find("Pay", in: app(AXNode(role: "AXGroup", label: "Pay", frame: rect(0, 0, 200, 200), children: [inner]))) == .found(inner))
    }

    @Test func `should not match the app itself`() {
        #expect(AXTarget.find("Skylark", in: app()) == .missing)
    }

    @Test func `should report an element that is disabled`() {
        let pay = button("Pay $1,240", rect(16, 717, 370, 58), enabled: false)

        #expect(AXTarget.find("Pay", in: app(pay)) == .disabled(pay))
    }

    @Test func `should find an element off screen, because a press doesn't need to reach it`() {
        let seat = button("Seat 20A", rect(48, 1000, 46, 40))

        #expect(AXTarget.find("Seat 20A", in: app(seat)) == .found(seat))
    }

    @Test func `should prefer the element on screen when the same name is also off it`() {
        let leaving = button("Continue", rect(-105, 700, 40, 40))
        let current = button("Continue", rect(100, 700, 40, 40))

        #expect(AXTarget.find("Continue", in: app(leaving, current)) == .found(current))
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

    @Test func `should give a real touch the centre of what's on screen, and no point when none is`() {
        let screen = AXScreen(width: 402, height: 874, orientation: .portrait)

        #expect(button("A", rect(28, 421, 346, 58)).touchPoint(on: screen) == Point(x: 201, y: 450))
        #expect(button("A", rect(36, 860, 100, 28)).touchPoint(on: screen) == Point(x: 86, y: 867))
        #expect(button("A", rect(48, 1000, 46, 40)).touchPoint(on: screen) == nil)
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

    @Test func `should act at once from a cheap look when the element is there`() {
        let (found, time, fullReads) = run(glances: [tree(pay())])

        #expect(found.lookup == .found(pay()))
        #expect(found.screen == Self.screen)
        #expect(time == 0)
        #expect(fullReads == 0)
    }

    @Test func `should take a full look for what only the sweep finds`() {
        let (found, _, fullReads) = run(glances: [tree()], reads: [tree(pay())])

        #expect(found.lookup == .found(pay()))
        #expect(fullReads == 1)
    }

    @Test func `should wait for an element that has not appeared yet`() {
        let (found, time, _) = run(glances: [tree(), tree(), tree(pay())])

        #expect(found.lookup == .found(pay()))
        #expect(time > 0)
        #expect(time < 1)
    }

    @Test func `should wait for a disabled element to become enabled`() {
        let (found, _, _) = run(glances: [tree(pay(enabled: false)), tree(pay())])

        #expect(found.lookup == .found(pay()))
    }

    @Test func `should give up and report the last thing it saw`() {
        let (found, time, _) = run(glances: [tree(pay(enabled: false))], reads: [tree(pay(enabled: false))])

        #expect(found.lookup == .disabled(pay(enabled: false)))
        #expect(time >= 1)
    }

    @Test func `should name a text field among what's visible when it has no label`() {
        let unnamed = AXNode(role: "AXTextField", subrole: "AXSearchField", value: "City or airport", frame: Self.somewhere)
        let email = AXNode(role: "AXTextField", value: "Email", identifier: "email", frame: Self.somewhere)
        let tree = AXNode(role: "AXApplication", frame: Self.somewhere, children: [unnamed, email])

        #expect(AXTarget.visibleNames(in: tree) == ["TextField", "email"])
    }

    @Test func `should leave an unnamed group out of what's visible`() {
        let group = AXNode(role: "AXGroup", frame: Self.somewhere)
        let tree = AXNode(role: "AXApplication", frame: Self.somewhere, children: [group])

        #expect(AXTarget.visibleNames(in: tree).isEmpty)
    }

    private func found(_ lookup: AXTarget.Lookup, tree: AXNode? = nil) -> AXTarget.Found {
        AXTarget.Found(lookup: lookup, screen: nil, tree: tree)
    }

    private static let somewhere = Rect(origin: Point(x: 0, y: 0), size: Size(width: 10, height: 10))

    @Test func `should not refuse when the name reached one element`() {
        let node = AXNode(role: "AXButton", label: "Pay", frame: Self.somewhere)
        #expect(found(.found(node)).refusal(of: "Pay") == nil)
    }

    @Test func `should say why when no element matches a name`() {
        let pay = AXNode(role: "AXButton", label: "Pay", frame: Self.somewhere)
        let tree = AXNode(role: "AXApplication", frame: Self.somewhere, children: [pay])

        let refusal = found(.missing, tree: tree).refusal(of: "Cancel")

        #expect(refusal?.message == "nothing matches Cancel")
        #expect(refusal?.details == ["visible": ["Pay"]])
    }

    @Test func `should say why when several elements match a name`() {
        let one = AXNode(role: "AXButton", label: "Pay", frame: Self.somewhere)
        let two = AXNode(role: "AXButton", label: "Pay now", frame: Self.somewhere)

        let refusal = found(.ambiguous([one, two])).refusal(of: "Pay")

        #expect(refusal?.message == "more than one element matches Pay")
        #expect(refusal?.details == ["matches": ["Pay", "Pay now"]])
    }

    @Test func `should say why when an element is disabled`() {
        let pay = AXNode(role: "AXButton", label: "Pay", frame: Self.somewhere, enabled: false)

        #expect(found(.disabled(pay)).refusal(of: "Pay")?.message == "Pay is disabled")
    }
}
