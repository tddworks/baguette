import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// Making one display main: every display placed around it, once the display
/// is listed — one made a moment ago is listed half a second later — and
/// checked that it took, for two seconds at most.
@Suite("MainDisplayMove")
struct MainDisplayMoveTests {
    final class Arrangement: @unchecked Sendable {
        private let lock = NSLock()
        var main: UInt32
        var listed: [[UInt32: Rect]]
        var placed: [[UInt32: Point]] = []
        let takes: Bool
        init(main: UInt32, listed: [[UInt32: Rect]], takes: Bool = true) {
            (self.main, self.listed, self.takes) = (main, listed, takes)
        }
        func read() -> [UInt32: Rect]? { lock.withLock { listed.count > 1 ? listed.removeFirst() : listed.first } }
        func place(_ origins: [UInt32: Point]) {
            lock.withLock {
                placed.append(origins)
                if takes, let new = origins.first(where: { $0.value == Point(x: 0, y: 0) })?.key { main = new }
            }
        }
    }

    static func rect(_ x: Double, _ width: Double) -> Rect { Rect(origin: Point(x: x, y: 0), size: Size(width: width, height: 1080)) }
    let side = [UInt32(1): rect(0, 1920), 2: rect(1920, 1080)]

    func move(_ arrangement: Arrangement) -> MainDisplayMove {
        let configuration = MockDisplayConfiguration()
        given(configuration).main.willProduce { arrangement.main }
        given(configuration).bounds().willProduce { arrangement.read() }
        given(configuration).place(.any).willProduce { arrangement.place($0) }
        return MainDisplayMove(configuration: configuration, pause: { _ in })
    }

    @Test func `should make a display main by placing every display around it`() {
        let arrangement = Arrangement(main: 1, listed: [side])
        #expect(move(arrangement).makeMain(2))
        #expect(arrangement.placed == [DisplayOrigins.makingMain(2, in: side, freeing: nil)!])
    }

    @Test func `should place nothing when the display is main already`() {
        let arrangement = Arrangement(main: 2, listed: [side])
        #expect(move(arrangement).makeMain(2))
        #expect(arrangement.placed.isEmpty)
    }

    @Test func `should wait for a display made a moment ago to be listed before placing it`() {
        let arrangement = Arrangement(main: 1, listed: [[1: Self.rect(0, 1920)], [1: Self.rect(0, 1920)], side])
        #expect(move(arrangement).makeMain(2))
        #expect(arrangement.placed.count == 1)
    }

    @Test func `should place the display at the Dock's end of the desktop when asked to free its edge`() {
        let arrangement = Arrangement(main: 1, listed: [[1: Self.rect(0, 1920), 2: Self.rect(-1080, 1080)]])
        #expect(move(arrangement).makeMain(2, freeing: .right))
        #expect(arrangement.placed == [[2: Point(x: 0, y: 0), 1: Point(x: -1920, y: 0)]])
    }

    @Test func `should give up after two seconds when the display never becomes main`() {
        let arrangement = Arrangement(main: 1, listed: [side], takes: false)
        #expect(!move(arrangement).makeMain(2))
        #expect(arrangement.placed.count == 40)
    }
}
