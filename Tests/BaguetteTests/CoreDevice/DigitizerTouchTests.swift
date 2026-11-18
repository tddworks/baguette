import Foundation
import Mockable
import Testing
@testable import Baguette

/// Gestures on a phone whose touches go through a digitizer: every report
/// the digitizer receives, in order, in fractions of the screen.
@Suite("DigitizerTouch")
struct DigitizerInputTests {
    private let size = Size(width: 400, height: 800)

    @Test func `should land a tap as a finger down then up at the same spot, in fractions of the screen`() {
        let (input, digitizer) = makeInput()

        #expect(input.tap(at: Point(x: 100, y: 200), size: size, duration: 0, edge: nil))

        #expect(digitizer.reports == [
            Report([Contact(x: 0.25, y: 0.25)], touching: true),
            Report([Contact(x: 0.25, y: 0.25)], touching: false),
        ])
    }

    @Test func `should hold a tap for as long as asked`() {
        let (input, _, pauses) = makeInputWithPauses()

        _ = input.tap(at: Point(x: 1, y: 1), size: size, duration: 0.5, edge: nil)

        #expect(pauses.total >= 0.5)
    }

    @Test func `should keep a touch on the screen when it is given outside it`() {
        let (input, digitizer) = makeInput()

        _ = input.tap(at: Point(x: -40, y: 900), size: size, duration: 0, edge: nil)

        #expect(digitizer.reports.first?.contacts == [Contact(x: 0, y: 1)])
    }

    @Test func `should drag a swipe through the points between start and end, then lift at the end`() {
        let (input, digitizer) = makeInput()

        #expect(input.swipe(from: Point(x: 0, y: 400), to: Point(x: 400, y: 400), size: size, duration: 0.2))

        let reports = digitizer.reports
        #expect(reports.first == Report([Contact(x: 0, y: 0.5)], touching: true))
        #expect(reports.last == Report([Contact(x: 1, y: 0.5)], touching: false))
        #expect(reports.count > 4)
        let xs = reports.dropLast().map { $0.contacts[0].x }
        #expect(xs == xs.sorted())
    }

    @Test func `should mark a touch that starts at an edge as a swipe in from that edge`() {
        let (input, digitizer) = makeInput()

        _ = input.touch1(phase: .down, at: Point(x: 200, y: 799), size: size, edge: .bottom)
        _ = input.touch1(phase: .move, at: Point(x: 200, y: 400), size: size, edge: .bottom)
        _ = input.touch1(phase: .up, at: Point(x: 200, y: 300), size: size, edge: .bottom)

        #expect(digitizer.reports.map(\.edge) == [.bottom, .bottom, .bottom])
        #expect(digitizer.reports.map(\.touching) == [true, true, false])
    }

    @Test func `should put two fingers down, move them and lift them for a two-finger touch`() {
        let (input, digitizer) = makeInput()

        _ = input.touch2(phase: .down, first: Point(x: 100, y: 400), second: Point(x: 300, y: 400), size: size)
        _ = input.touch2(phase: .up, first: Point(x: 0, y: 400), second: Point(x: 400, y: 400), size: size)

        #expect(digitizer.reports == [
            Report([Contact(x: 0.25, y: 0.5), Contact(x: 0.75, y: 0.5)], touching: true),
            Report([Contact(x: 0, y: 0.5), Contact(x: 1, y: 0.5)], touching: false),
        ])
    }

    @Test func `should move two fingers along their own paths together`() {
        let (input, digitizer) = makeInput()

        _ = input.twoFingerPath(
            start1: Point(x: 200, y: 300), end1: Point(x: 200, y: 100),
            start2: Point(x: 200, y: 500), end2: Point(x: 200, y: 700),
            size: size, duration: 0.2)

        let reports = digitizer.reports
        #expect(reports.allSatisfy { $0.contacts.count == 2 })
        #expect(reports.first?.contacts == [Contact(x: 0.5, y: 0.375), Contact(x: 0.5, y: 0.625)])
        #expect(reports.last?.contacts == [Contact(x: 0.5, y: 0.125), Contact(x: 0.5, y: 0.875)])
        #expect(reports.last?.touching == false)
    }

    @Test func `should say a gesture failed when the digitizer drops a report`() {
        let digitizer = Reports(accepting: false)

        let ok = DigitizerTouch(digitizer: digitizer.mock, pause: { _ in })
            .tap(at: Point(x: 1, y: 1), size: size, duration: 0, edge: nil)

        #expect(!ok)
    }

    private func makeInput() -> (DigitizerTouch, Reports) {
        let digitizer = Reports()
        return (DigitizerTouch(digitizer: digitizer.mock, pause: { _ in }), digitizer)
    }

    private func makeInputWithPauses() -> (DigitizerTouch, Reports, Pauses) {
        let digitizer = Reports()
        let pauses = Pauses()
        return (DigitizerTouch(digitizer: digitizer.mock, pause: { pauses.add($0) }), digitizer, pauses)
    }
}

struct Report: Equatable {
    let contacts: [Contact]
    let touching: Bool
    var edge: DeviceEdge?
    init(_ contacts: [Contact], touching: Bool, edge: DeviceEdge? = nil) {
        self.contacts = contacts
        self.touching = touching
        self.edge = edge
    }
}

final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Report] = []
    let mock = MockDigitizer()

    init(accepting: Bool = true) {
        given(mock).report(.any, touching: .any, edge: .any).willProduce { [self] contacts, touching, edge in
            lock.withLock { recorded.append(Report(contacts, touching: touching, edge: edge)) }
            return accepting
        }
    }

    var reports: [Report] { lock.withLock { recorded } }
}

final class Pauses: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds = 0.0
    func add(_ value: Double) { lock.withLock { seconds += value } }
    var total: Double { lock.withLock { seconds } }
}
