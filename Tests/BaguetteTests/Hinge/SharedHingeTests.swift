import Testing
import Foundation
import Mockable
@testable import Baguette

/// One monitor per device. Every stream socket on a foldable wants the
/// sweep and every bind wants the current angle; spawning a devicectl
/// per caller put several monitors on one device at once and a fresh
/// spawn on every resolve. `SharedHinge` runs a single inner watch,
/// fans its samples out, and answers `angle()` from the last sample
/// while it runs.
@Suite("SharedHinge")
struct SharedHingeTests {

    final class Inner: @unchecked Sendable {
        let hinge = MockHinge()
        let watch = MockHingeWatch()
        var onAngle: (@Sendable (HingeAngle) -> Void)?
        var watches = 0
        init() {
            given(hinge).watch(onAngle: .any).willProduce { [self] cb in
                self.onAngle = cb
                self.watches += 1
                return self.watch
            }
            given(watch).cancel().willReturn()
        }
    }

    final class Seen: @unchecked Sendable { var angles: [Double] = [] }

    @Test func `subscribers share one inner watch and all receive each sample`() {
        let inner = Inner()
        let shared = SharedHinge(inner: inner.hinge)
        let a = Seen(), b = Seen()
        let wa = shared.watch { a.angles.append($0.degrees) }
        let wb = shared.watch { b.angles.append($0.degrees) }
        inner.onAngle?(HingeAngle(degrees: 3.8))
        inner.onAngle?(HingeAngle(degrees: 57))
        #expect(inner.watches == 1)
        #expect(a.angles == [3.8, 57])
        #expect(b.angles == [3.8, 57])
        wa.cancel(); wb.cancel()
    }

    /// A foldable's page opens its stream and the book's cover feed
    /// together, so two sockets subscribe at once. Both used to see no
    /// monitor and start one; the second overwrote the first, which was
    /// never stopped — and a second concurrent devicectl monitor answers
    /// wrong angles, so the page flipped panels on stale samples.
    @Test func `two watchers joining while the monitor starts share one monitor`() {
        let hinge = SlowStartingHinge()
        let shared = SharedHinge(inner: hinge)
        final class Box: @unchecked Sendable { var watch: (any HingeWatch)? }
        let first = Box()
        let firstJoined = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            first.watch = shared.watch { _ in }
            firstJoined.signal()
        }
        hinge.starting.wait()
        let second = shared.watch { _ in }
        hinge.gate.signal()
        firstJoined.wait()
        #expect(hinge.starts == 1)
        second.cancel()
        first.watch?.cancel()
        #expect(hinge.cancels == 1)
    }

    /// A monitor whose first start takes a while, as devicectl's does. A
    /// hand-rolled fake: a generated mock serialises its calls, so a start
    /// held open would lock out the second caller this test is about.
    final class SlowStartingHinge: Hinge, @unchecked Sendable {
        let starting = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var startCount = 0, cancelCount = 0
        var starts: Int { lock.withLock { startCount } }
        var cancels: Int { lock.withLock { cancelCount } }

        func angle() -> HingeAngle? { nil }
        func fold(to degrees: Double, over duration: TimeInterval) throws {}
        func watch(onAngle: @escaping @Sendable (HingeAngle) -> Void) -> any HingeWatch {
            let first = lock.withLock { startCount += 1; return startCount == 1 }
            if first { starting.signal(); gate.wait() }
            return Stop { [self] in lock.withLock { cancelCount += 1 } }
        }

        final class Stop: HingeWatch, @unchecked Sendable {
            let run: () -> Void
            init(_ run: @escaping () -> Void) { self.run = run }
            func cancel() { run() }
        }
    }

    @Test func `a watcher joining a running monitor is told the standing angle at once`() {
        // devicectl reports a change-driven stream: the standing angle
        // comes once, at start. A socket that joins later — a 3D scene
        // opened while the page's own socket already watches — would
        // otherwise wait for the hinge to move before it could pose.
        let inner = Inner()
        let shared = SharedHinge(inner: inner.hinge)
        let first = shared.watch { _ in }
        inner.onAngle?(HingeAngle(degrees: 130))
        let late = Seen()
        let w = shared.watch { late.angles.append($0.degrees) }
        #expect(late.angles == [130])
        inner.onAngle?(HingeAngle(degrees: 120))
        #expect(late.angles == [130, 120])
        w.cancel(); first.cancel()
    }

    @Test func `while watched, the angle is the last sample with no read`() {
        let inner = Inner()
        let shared = SharedHinge(inner: inner.hinge)
        let w = shared.watch { _ in }
        inner.onAngle?(HingeAngle(degrees: 130))
        #expect(shared.angle() == HingeAngle(degrees: 130))
        verify(inner.hinge).angle().called(0)
        w.cancel()
    }

    @Test func `with no watch running, the angle is read`() {
        let inner = Inner()
        given(inner.hinge).angle().willReturn(HingeAngle(degrees: 0))
        let shared = SharedHinge(inner: inner.hinge)
        #expect(shared.angle() == HingeAngle(degrees: 0))
        verify(inner.hinge).angle().called(1)
    }

    /// Before the monitor's first sample lands there is nothing cached;
    /// a read answers rather than a stale `nil`.
    @Test func `a watch that has not sampled yet does not shadow a read`() {
        let inner = Inner()
        given(inner.hinge).angle().willReturn(HingeAngle(degrees: 180))
        let shared = SharedHinge(inner: inner.hinge)
        let w = shared.watch { _ in }
        #expect(shared.angle() == HingeAngle(degrees: 180))
        w.cancel()
    }

    @Test func `the inner watch stops when the last subscriber leaves, not before`() {
        let inner = Inner()
        let shared = SharedHinge(inner: inner.hinge)
        let wa = shared.watch { _ in }
        let wb = shared.watch { _ in }
        wa.cancel()
        verify(inner.watch).cancel().called(0)
        wb.cancel()
        verify(inner.watch).cancel().called(1)
    }

    @Test func `a cancelled subscriber receives nothing more`() {
        let inner = Inner()
        let shared = SharedHinge(inner: inner.hinge)
        let a = Seen()
        let wa = shared.watch { a.angles.append($0.degrees) }
        let wb = shared.watch { _ in }
        wa.cancel()
        inner.onAngle?(HingeAngle(degrees: 90))
        #expect(a.angles.isEmpty)
        wb.cancel()
    }

    /// A pose change ends with the page reloading, which closes the
    /// socket — and so the watch — a moment before the new page's
    /// definition, mask and stream requests each ask the angle. Those
    /// must agree, and the sweep's last sample is the truth for a
    /// while: the hinge does not move without Device Hub, and the new
    /// page's socket restarts the watch within seconds.
    @Test func `the last sample outlives the watch for a grace period`() {
        let inner = Inner()
        var now = Date(timeIntervalSince1970: 1000)
        let shared = SharedHinge(inner: inner.hinge, now: { now })
        let w = shared.watch { _ in }
        inner.onAngle?(HingeAngle(degrees: 4.8))
        w.cancel()
        now = now.addingTimeInterval(3)
        #expect(shared.angle() == HingeAngle(degrees: 4.8))
        verify(inner.hinge).angle().called(0)
    }

    @Test func `after the grace period the angle is read again`() {
        let inner = Inner()
        given(inner.hinge).angle().willReturn(HingeAngle(degrees: 130))
        var now = Date(timeIntervalSince1970: 1000)
        let shared = SharedHinge(inner: inner.hinge, now: { now })
        let w = shared.watch { _ in }
        inner.onAngle?(HingeAngle(degrees: 4.8))
        w.cancel()
        now = now.addingTimeInterval(SharedHinge.gracePeriod + 1)
        #expect(shared.angle() == HingeAngle(degrees: 130))
    }

    /// A page reload asks the angle from several requests at once —
    /// `/hinge`, the definition, the stream bind — before any socket
    /// has restarted the watch. Each spawning its own monitor is what
    /// produced disagreeing panels (a second concurrent devicectl
    /// monitor answers 0° for a device sitting at 130°). One read
    /// serves the burst: the first spawns, the rest share its sample.
    @Test func `a one-shot read is remembered for the grace period`() {
        let inner = Inner()
        given(inner.hinge).angle().willReturn(HingeAngle(degrees: 130))
        var now = Date(timeIntervalSince1970: 1000)
        let shared = SharedHinge(inner: inner.hinge, now: { now })
        #expect(shared.angle() == HingeAngle(degrees: 130))
        now = now.addingTimeInterval(2)
        #expect(shared.angle() == HingeAngle(degrees: 130))
        verify(inner.hinge).angle().called(1)
    }

    /// A failed read is not remembered — the next caller tries again.
    @Test func `a read that returns nothing is not cached as an angle, but is not retried at once`() {
        // A silent hinge (the guest's motion stream can drop after a
        // SpringBoard restart) makes every read wait out its deadline;
        // callers queue behind the serialised read and the server
        // stalls. The silence is remembered for a short while instead.
        var clock = Date(timeIntervalSince1970: 1_000)
        let inner = Inner()
        given(inner.hinge).angle().willReturn(nil)
        let shared = SharedHinge(inner: inner.hinge, now: { clock })
        #expect(shared.angle() == nil)
        #expect(shared.angle() == nil)
        verify(inner.hinge).angle().called(1)
        clock = clock.addingTimeInterval(SharedHinge.silencePeriod + 0.1)
        #expect(shared.angle() == nil)
        verify(inner.hinge).angle().called(2)
    }

    @Test func `folding sweeps from the angle last heard to the one asked for`() throws {
        let inner = Inner()
        let motor = MockHingeMotor()
        given(motor).fold(from: .any, to: .any, over: .any).willReturn()
        let shared = SharedHinge(inner: inner.hinge, motor: motor)
        let w = shared.watch { _ in }
        inner.onAngle?(HingeAngle(degrees: 130))

        try shared.fold(to: 0, over: 0.8)

        verify(motor).fold(from: .value(130), to: .value(0), over: .value(0.8)).called(1)
        w.cancel()
    }

    @Test func `with no angle heard, a fold starts from shut`() throws {
        let inner = Inner()
        given(inner.hinge).angle().willReturn(nil)
        let motor = MockHingeMotor()
        given(motor).fold(from: .any, to: .any, over: .any).willReturn()
        let shared = SharedHinge(inner: inner.hinge, motor: motor)

        try shared.fold(to: 130, over: 0.8)

        verify(motor).fold(from: .value(0), to: .value(130), over: .value(0.8)).called(1)
    }

    /// The same device always gets the same shared hinge, whoever asks.
    @Test func `the registry hands out one shared hinge per device`() {
        let inner = Inner()
        let first = SharedHinge.forDevice("duo", make: { inner.hinge })
        let second = SharedHinge.forDevice("duo", make: { MockHinge() })
        #expect(first === second)
        #expect(SharedHinge.forDevice("other", make: { MockHinge() }) !== first)
    }
}
