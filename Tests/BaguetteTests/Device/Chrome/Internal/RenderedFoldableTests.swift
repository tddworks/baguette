import Foundation
import IOSurface
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

// A foldable has two screens and a hinge. Frames from either panel
// compose through one scene, posed at the hinge's latest angle, with the
// latest frame of each panel on its screen.
@Suite("RenderedFoldable")
struct RenderedFoldableTests {
    @Test func `should render a frame from either panel with the latest frame of both`() throws {
        let unfolded = MockScreen(), cover = MockScreen()
        let hinge = MockHinge(), watch = MockHingeWatch()
        let scene = MockDeviceScene()
        let inner = try #require(RenderedScreenTests.surface(width: 2, height: 2))
        let outer = try #require(RenderedScreenTests.surface(width: 3, height: 3))
        let rendered = try #require(RenderedScreenTests.surface(width: 4, height: 3))
        var innerDelivery: (@Sendable (IOSurface) -> Void)?
        var coverDelivery: (@Sendable (IOSurface) -> Void)?
        given(unfolded).start(onFrame: .any).willProduce { innerDelivery = $0 }
        given(cover).start(onFrame: .any).willProduce { coverDelivery = $0 }
        given(unfolded).stop().willReturn()
        given(cover).stop().willReturn()
        given(hinge).angle().willReturn(HingeAngle(degrees: 130))
        given(hinge).watch(onAngle: .any).willReturn(watch)
        given(hinge).watchSweeps(onSweep: .any).willReturn(MockHingeWatch.unheard())
        given(watch).cancel().willReturn()
        given(scene).update(hingeDegrees: .any).willReturn()
        let seen = LockedScreens()
        given(scene).render(screens: .any).willProduce { screens in
            seen.append(screens); return rendered
        }
        let screen = RenderedFoldable(unfolded: unfolded, cover: cover, hinge: hinge, scene: scene)
        let delivered = LockedCount()

        try screen.start { _ in delivered.increment() }
        innerDelivery?(inner)
        #expect(RenderedScreenTests.waitUntil { delivered.value == 1 })
        coverDelivery?(outer)
        #expect(RenderedScreenTests.waitUntil { delivered.value == 2 })
        screen.stop()

        #expect(seen.value == [
            FoldableScreens(unfolded: inner, cover: nil),
            FoldableScreens(unfolded: inner, cover: outer),
        ])
        verify(unfolded).stop().called(1)
        verify(cover).stop().called(1)
        verify(watch).cancel().called(1)
    }

    @Test func `should pose the scene and recompose the latest frames when the hinge moves`() throws {
        let unfolded = MockScreen(), cover = MockScreen()
        let hinge = MockHinge(), watch = MockHingeWatch()
        let scene = MockDeviceScene()
        let inner = try #require(RenderedScreenTests.surface(width: 2, height: 2))
        let rendered = try #require(RenderedScreenTests.surface(width: 4, height: 3))
        var innerDelivery: (@Sendable (IOSurface) -> Void)?
        var onAngle: ((HingeAngle) -> Void)?
        given(unfolded).start(onFrame: .any).willProduce { innerDelivery = $0 }
        given(cover).start(onFrame: .any).willReturn()
        given(hinge).angle().willReturn(HingeAngle(degrees: 130))
        given(hinge).watch(onAngle: .any).willProduce { onAngle = $0; return watch }
        given(hinge).watchSweeps(onSweep: .any).willReturn(MockHingeWatch.unheard())
        given(scene).update(hingeDegrees: .any).willReturn()
        let renders = LockedCount()
        given(scene).render(screens: .any).willProduce { _ in renders.increment(); return rendered }
        let screen = RenderedFoldable(unfolded: unfolded, cover: cover, hinge: hinge, scene: scene)
        try screen.start { _ in }
        innerDelivery?(inner)
        #expect(RenderedScreenTests.waitUntil { renders.value == 1 })

        onAngle?(HingeAngle(degrees: 120))

        #expect(RenderedScreenTests.waitUntil { renders.value == 2 })
        verify(scene).update(hingeDegrees: .value(120)).called(1)
    }

    @Test func `should show the pose at the hinge's own angle`() throws {
        let unfolded = MockScreen(), cover = MockScreen()
        let hinge = MockHinge(), watch = MockHingeWatch()
        let scene = MockDeviceScene()
        var onAngle: ((HingeAngle) -> Void)?
        given(unfolded).start(onFrame: .any).willReturn()
        given(cover).start(onFrame: .any).willReturn()
        given(hinge).angle().willReturn(HingeAngle(degrees: 130))
        given(hinge).watch(onAngle: .any).willProduce { onAngle = $0; return watch }
        given(hinge).watchSweeps(onSweep: .any).willReturn(MockHingeWatch.unheard())
        given(scene).update(hingeDegrees: .any).willReturn()
        let screen = RenderedFoldable(unfolded: unfolded, cover: cover, hinge: hinge, scene: scene)
        try screen.start { _ in }
        #expect(screen.pose == FoldablePose(hingeDegrees: 130))
        onAngle?(HingeAngle(degrees: 42))
        #expect(screen.pose == FoldablePose(hingeDegrees: 42))
    }

    @Test func `should tell whoever follows the book the pose it now stands at when the hinge moves`() throws {
        let unfolded = MockScreen(), cover = MockScreen()
        let hinge = MockHinge(), watch = MockHingeWatch()
        let scene = MockDeviceScene()
        var onAngle: ((HingeAngle) -> Void)?
        given(unfolded).start(onFrame: .any).willReturn()
        given(cover).start(onFrame: .any).willReturn()
        given(hinge).angle().willReturn(HingeAngle(degrees: 130))
        given(hinge).watch(onAngle: .any).willProduce { onAngle = $0; return watch }
        given(hinge).watchSweeps(onSweep: .any).willReturn(MockHingeWatch.unheard())
        given(scene).update(hingeDegrees: .any).willReturn()
        let heard = LockedPoses()
        let screen = RenderedFoldable(
            unfolded: unfolded, cover: cover, hinge: hinge, scene: scene,
            onPose: { heard.append($0) })
        try screen.start { _ in }

        onAngle?(HingeAngle(degrees: 42))

        #expect(heard.value == [FoldablePose(hingeDegrees: 42)])
    }

    @Test func `should let the book and its scene go once the stream ends while someone follows its pose`() throws {
        // The live 3D socket follows the pose to push the screen's
        // placement; a listener that held the book to read its pose kept
        // the book, its scene and the socket alive after every close.
        let unfolded = MockScreen(), cover = MockScreen()
        let hinge = MockHinge(), watch = MockHingeWatch()
        var onAngle: ((HingeAngle) -> Void)?
        given(unfolded).start(onFrame: .any).willReturn()
        given(cover).start(onFrame: .any).willReturn()
        given(unfolded).stop().willReturn()
        given(cover).stop().willReturn()
        given(hinge).angle().willReturn(HingeAngle(degrees: 130))
        given(hinge).watch(onAngle: .any).willProduce { onAngle = $0; return watch }
        given(hinge).watchSweeps(onSweep: .any).willReturn(MockHingeWatch.unheard())
        given(watch).cancel().willReturn()
        weak var leftBook: RenderedFoldable?
        weak var leftScene: MockDeviceScene?
        let heard = LockedPoses()
        do {
            let scene = MockDeviceScene()
            given(scene).update(hingeDegrees: .any).willReturn()
            let book = RenderedFoldable(
                unfolded: unfolded, cover: cover, hinge: hinge, scene: scene,
                onPose: { [scene] pose in _ = scene; heard.append(pose) })
            leftBook = book
            leftScene = scene
            try book.start { _ in }
            onAngle?(HingeAngle(degrees: 42))
            book.stop()
        }
        onAngle = nil

        #expect(heard.value == [FoldablePose(hingeDegrees: 42)])
        #expect(leftBook == nil)
        #expect(leftScene == nil)
    }

    @Test func `should pose the book at the standing angle before composing any frame`() throws {
        // A scene starts flat; a frame composed before the hinge has
        // spoken would show the book open when it is shut.
        let unfolded = MockScreen(), cover = MockScreen()
        let hinge = MockHinge(), watch = MockHingeWatch()
        let scene = MockDeviceScene()
        let inner = try #require(RenderedScreenTests.surface(width: 2, height: 2))
        let rendered = try #require(RenderedScreenTests.surface(width: 4, height: 3))
        var innerDelivery: (@Sendable (IOSurface) -> Void)?
        var onAngle: ((HingeAngle) -> Void)?
        given(unfolded).start(onFrame: .any).willProduce { innerDelivery = $0 }
        given(cover).start(onFrame: .any).willReturn()
        given(hinge).angle().willReturn(HingeAngle(degrees: 0))
        given(hinge).watch(onAngle: .any).willProduce { onAngle = $0; return watch }
        given(hinge).watchSweeps(onSweep: .any).willReturn(MockHingeWatch.unheard())
        let order = LockedLog()
        given(scene).update(hingeDegrees: .any).willProduce { order.append("pose \($0)") }
        given(scene).render(screens: .any).willProduce { _ in order.append("render"); return rendered }
        let screen = RenderedFoldable(unfolded: unfolded, cover: cover, hinge: hinge, scene: scene)

        try screen.start { _ in }
        innerDelivery?(inner)
        #expect(RenderedScreenTests.waitUntil { order.value.contains("render") })
        #expect(order.value.first == "pose 0.0")

        // With no standing angle — the guest's motion stream can be
        // silent — the book is shown shut, as it boots, until the hinge
        // speaks: a blank stage helps nobody.
        let mute = MockHinge()
        given(mute).angle().willReturn(nil)
        given(mute).watch(onAngle: .any).willProduce { onAngle = $0; return watch }
        given(mute).watchSweeps(onSweep: .any).willReturn(MockHingeWatch.unheard())
        let late = LockedLog()
        let scene2 = MockDeviceScene()
        given(scene2).update(hingeDegrees: .any).willProduce { late.append("pose \($0)") }
        given(scene2).render(screens: .any).willProduce { _ in late.append("render"); return rendered }
        let unfolded2 = MockScreen(), cover2 = MockScreen()
        var delivery2: (@Sendable (IOSurface) -> Void)?
        given(unfolded2).start(onFrame: .any).willProduce { delivery2 = $0 }
        given(cover2).start(onFrame: .any).willReturn()
        let waiting = RenderedFoldable(unfolded: unfolded2, cover: cover2, hinge: mute, scene: scene2)
        try waiting.start { _ in }
        delivery2?(inner)
        #expect(RenderedScreenTests.waitUntil { late.value == ["pose 0.0", "render"] })
        onAngle?(HingeAngle(degrees: 3.8))
        #expect(RenderedScreenTests.waitUntil { late.value == ["pose 0.0", "render", "pose 3.8", "render"] })
    }

    /// A book on its hinge, the sweeps it is told of, and every pose it took.
    fileprivate final class Book: @unchecked Sendable {
        let hinge = MockHinge()
        let scene = MockDeviceScene()
        let watch = MockHingeWatch(), sweeps = MockHingeWatch()
        let posed = LockedDegrees()
        let heard = LockedPoses()
        let clock = Clock()
        var onAngle: ((HingeAngle) -> Void)?
        var onSweep: ((HingeSweepEvent) -> Void)?
        lazy var screen = RenderedFoldable(
            unfolded: Self.dark(), cover: Self.dark(), hinge: hinge, scene: scene,
            onPose: { [heard] in heard.append($0) }, now: { [clock] in clock.now })

        /// The book's time, moved by hand so a sweep's frames do not
        /// depend on how often a busy machine runs the timer.
        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var seconds: TimeInterval = 100
            var now: TimeInterval { lock.withLock { seconds } }
            func set(_ value: TimeInterval) { lock.withLock { seconds = value } }
        }

        init(standing: Double) {
            given(hinge).angle().willReturn(HingeAngle(degrees: standing))
            given(hinge).watch(onAngle: .any).willProduce { [unowned self] in self.onAngle = $0; return self.watch }
            given(hinge).watchSweeps(onSweep: .any).willProduce { [unowned self] in self.onSweep = $0; return self.sweeps }
            given(watch).cancel().willReturn()
            given(sweeps).cancel().willReturn()
            given(scene).update(hingeDegrees: .any).willProduce { [posed] in posed.append($0) }
        }

        private static func dark() -> MockScreen {
            let screen = MockScreen()
            given(screen).start(onFrame: .any).willReturn()
            given(screen).stop().willReturn()
            return screen
        }
    }

    @Test func `should pose the book along the sweep baguette plays rather than the late readings`() throws {
        let book = Book(standing: 180)
        try book.screen.start { _ in }
        defer { book.screen.stop() }
        let sweep = HingeSweep(from: 180, to: 130, duration: 0.25)

        book.onSweep?(.began(sweep))
        book.onAngle?(HingeAngle(degrees: 176.9))

        for elapsed in [0, 0.05, 0.1, 0.15, 0.25] {
            book.clock.set(100 + elapsed)
            let frame = sweep.degrees(after: elapsed)
            #expect(RenderedScreenTests.waitUntil(timeout: 5) { book.posed.degrees.last == frame })
        }
        #expect(book.posed.degrees.last == 130)
        #expect(!book.posed.degrees.contains(176.9))
        // `onPose` follows each pose's `scene.update`, so wait for the last.
        #expect(RenderedScreenTests.waitUntil(timeout: 5) {
            book.heard.value.map(\.hingeDegrees) == Array(book.posed.degrees.dropFirst())
        })
    }

    @Test func `should settle on the hinge's reading once the sweep is delivered and the reading lands`() throws {
        let book = Book(standing: 180)
        try book.screen.start { _ in }
        defer { book.screen.stop() }
        book.onSweep?(.began(HingeSweep(from: 180, to: 130, duration: 0)))
        #expect(RenderedScreenTests.waitUntil { book.posed.degrees.last == 130 })

        book.onSweep?(.ended(.delivered))
        book.onAngle?(HingeAngle(degrees: 150))
        book.onAngle?(HingeAngle(degrees: 130.2))

        #expect(RenderedScreenTests.waitUntil { book.posed.degrees.last == 130.2 })
        #expect(!book.posed.degrees.contains(150))
        book.onAngle?(HingeAngle(degrees: 100))
        #expect(book.posed.degrees.last == 100)
    }

    @Test func `should follow the reading at once when the guest refused the sweep`() throws {
        let book = Book(standing: 180)
        try book.screen.start { _ in }
        defer { book.screen.stop() }
        book.onSweep?(.began(HingeSweep(from: 180, to: 130, duration: 0)))
        #expect(RenderedScreenTests.waitUntil { book.posed.degrees.last == 130 })

        book.onSweep?(.ended(.rejected))

        #expect(RenderedScreenTests.waitUntil { book.posed.degrees.last == 180 })
    }

    @Test func `should stop playing a sweep and hearing of sweeps once the stream ends`() throws {
        let book = Book(standing: 180)
        try book.screen.start { _ in }
        let sweep = HingeSweep(from: 180, to: 0, duration: 1)
        book.onSweep?(.began(sweep))
        #expect(RenderedScreenTests.waitUntil(timeout: 5) { book.posed.degrees.last == sweep.degrees(after: 0) })

        book.screen.stop()
        book.clock.set(100.5)
        Thread.sleep(forTimeInterval: 0.1)

        #expect(book.posed.degrees.last == sweep.degrees(after: 0))
        verify(book.sweeps).cancel().called(1)
    }
}

extension MockHingeWatch {
    /// The sweep watch of a hinge nobody folds.
    static func unheard() -> MockHingeWatch {
        let watch = MockHingeWatch()
        given(watch).cancel().willReturn()
        return watch
    }
}

final class LockedDegrees: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    var degrees: [Double] { lock.withLock { storage } }
    func append(_ degrees: Double) { lock.withLock { storage.append(degrees) } }
}

private final class LockedScreens: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [FoldableScreens] = []
    var value: [FoldableScreens] { lock.withLock { storage } }
    func append(_ screens: FoldableScreens) { lock.withLock { storage.append(screens) } }
}

private final class LockedPoses: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [FoldablePose] = []
    var value: [FoldablePose] { lock.withLock { storage } }
    func append(_ pose: FoldablePose) { lock.withLock { storage.append(pose) } }
}

private final class LockedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var value: [String] { lock.withLock { storage } }
    func append(_ entry: String) { lock.withLock { storage.append(entry) } }
}

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}
