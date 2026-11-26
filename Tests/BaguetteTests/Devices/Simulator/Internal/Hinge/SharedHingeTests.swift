import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// One monitor per device. Every stream socket on a foldable wants the
/// sweep and every bind wants the current angle; spawning a reader
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

    @Test func `should share one inner watch and deliver each sample to every subscriber`() {
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

    @Test func `should tell a watcher joining a running monitor the standing angle at once`() {
        // The hinge reports a change-driven stream: the standing angle
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

    @Test func `should answer the angle from the last sample without a read while watched`() {
        let inner = Inner()
        let shared = SharedHinge(inner: inner.hinge)
        let w = shared.watch { _ in }
        inner.onAngle?(HingeAngle(degrees: 130))
        #expect(shared.angle() == HingeAngle(degrees: 130))
        verify(inner.hinge).angle().called(0)
        w.cancel()
    }

    @Test func `should read the angle when no watch is running`() {
        let inner = Inner()
        given(inner.hinge).angle().willReturn(HingeAngle(degrees: 0))
        let shared = SharedHinge(inner: inner.hinge)
        #expect(shared.angle() == HingeAngle(degrees: 0))
        verify(inner.hinge).angle().called(1)
    }

    /// Before the monitor's first sample lands there is nothing cached;
    /// a read answers rather than a stale `nil`.
    @Test func `should still read the angle when a watch has not sampled yet`() {
        let inner = Inner()
        given(inner.hinge).angle().willReturn(HingeAngle(degrees: 180))
        let shared = SharedHinge(inner: inner.hinge)
        let w = shared.watch { _ in }
        #expect(shared.angle() == HingeAngle(degrees: 180))
        w.cancel()
    }

    @Test func `should stop the inner watch when the last subscriber leaves, not before`() {
        let inner = Inner()
        let shared = SharedHinge(inner: inner.hinge)
        let wa = shared.watch { _ in }
        let wb = shared.watch { _ in }
        wa.cancel()
        verify(inner.watch).cancel().called(0)
        wb.cancel()
        verify(inner.watch).cancel().called(1)
    }

    @Test func `should deliver nothing more to a cancelled subscriber`() {
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
    @Test func `should keep the last sample for a grace period after the watch ends`() {
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

    @Test func `should read the angle again after the grace period`() {
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
    /// monitor once answered 0° for a device sitting at 130°). One read
    /// serves the burst: the first spawns, the rest share its sample.
    @Test func `should remember a one-shot read for the grace period`() {
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
    @Test func `should not cache a silent read as an angle, but not retry it at once either`() {
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

    @Test func `should fold from the angle last heard to the one asked for`() throws {
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

    /// Without `HingeControl`, or with the guest silent, nothing is
    /// heard. Sweeping from an assumed shut would fold an open device
    /// closed and hand the display to the cover and back on the way to
    /// the angle asked for.
    @Test func `should fold straight to the angle asked for when no angle was heard`() throws {
        let inner = Inner()
        given(inner.hinge).angle().willReturn(nil)
        let motor = MockHingeMotor()
        given(motor).fold(from: .any, to: .any, over: .any).willReturn()
        let shared = SharedHinge(inner: inner.hinge, motor: motor)

        try shared.fold(to: 130, over: 0.8)

        verify(motor).fold(from: .value(130), to: .value(130), over: .value(0.8)).called(1)
    }

    /// Where the guest's hinge is; a fold moves it.
    final class Device: @unchecked Sendable {
        var angle: HingeAngle?
        init(_ angle: HingeAngle?) { self.angle = angle }
    }

    private func folding(_ device: Device, failing error: HingeError? = nil) -> MockHingeMotor {
        let motor = MockHingeMotor()
        given(motor).fold(from: .any, to: .any, over: .any).willProduce { _, to, _ in
            device.angle = HingeAngle(degrees: to)
            if let error { throw error }
        }
        return motor
    }

    /// Clients rebind their stream as soon as a fold returns. The angle
    /// read to start the sweep is the hinge before it, not after.
    @Test func `should report the angle the hinge folded to when nothing is watching`() throws {
        let inner = Inner()
        let device = Device(HingeAngle(degrees: 130))
        given(inner.hinge).angle().willProduce { device.angle }
        let shared = SharedHinge(inner: inner.hinge, motor: folding(device))

        try shared.fold(to: 0, over: 0.8)

        #expect(shared.angle() == HingeAngle(degrees: 0))
        #expect(shared.angle()?.litPanel == .primary)
    }

    /// A fold that timed out may have landed before the helper stopped.
    @Test func `should read the hinge again when a fold fails and nothing is watching`() {
        let inner = Inner()
        let device = Device(HingeAngle(degrees: 130))
        given(inner.hinge).angle().willProduce { device.angle }
        let shared = SharedHinge(inner: inner.hinge, motor: folding(device, failing: .toolTimedOut))

        #expect(throws: HingeError.toolTimedOut) { try shared.fold(to: 0, over: 0.8) }

        #expect(shared.angle() == HingeAngle(degrees: 0))
    }

    /// A move is what wakes a hinge that went silent after a SpringBoard
    /// restart, so the silence is not held against the read after it.
    @Test func `should read a silent hinge again after a fold`() throws {
        let inner = Inner()
        let device = Device(nil)
        given(inner.hinge).angle().willProduce { device.angle }
        let shared = SharedHinge(inner: inner.hinge, motor: folding(device))
        #expect(shared.angle() == nil)

        try shared.fold(to: 130, over: 0.8)

        #expect(shared.angle() == HingeAngle(degrees: 130))
    }

    /// A running watch hears the sweep itself; its last sample answers.
    @Test func `should keep answering from the watch after a fold while one runs`() throws {
        let inner = Inner()
        given(inner.hinge).angle().willReturn(HingeAngle(degrees: 77))
        let motor = MockHingeMotor()
        given(motor).fold(from: .any, to: .any, over: .any).willProduce { _, to, _ in
            inner.onAngle?(HingeAngle(degrees: to))
        }
        let shared = SharedHinge(inner: inner.hinge, motor: motor)
        let w = shared.watch { _ in }
        inner.onAngle?(HingeAngle(degrees: 130))

        try shared.fold(to: 0, over: 0.8)

        #expect(shared.angle() == HingeAngle(degrees: 0))
        verify(inner.hinge).angle().called(0)
        w.cancel()
    }

    /// A watch whose reader stopped still holds its subscribers, but
    /// it hears nothing; its last sample is from before the fold.
    @Test func `should read the hinge again after a fold the watch did not hear`() throws {
        let inner = Inner()
        let device = Device(HingeAngle(degrees: 130))
        given(inner.hinge).angle().willProduce { device.angle }
        let shared = SharedHinge(inner: inner.hinge, motor: folding(device))
        let w = shared.watch { _ in }
        inner.onAngle?(HingeAngle(degrees: 130))

        try shared.fold(to: 0, over: 0.8)

        #expect(shared.angle() == HingeAngle(degrees: 0))
        w.cancel()
    }

    /// A watch started just before the fold can deliver its standing
    /// sample — the hinge before the fold — while the fold plays.
    @Test func `should read the hinge again after a fold when the watch only heard the angle before it`() throws {
        let inner = Inner()
        let device = Device(HingeAngle(degrees: 130))
        given(inner.hinge).angle().willProduce { device.angle }
        let motor = MockHingeMotor()
        given(motor).fold(from: .any, to: .any, over: .any).willProduce { _, to, _ in
            inner.onAngle?(HingeAngle(degrees: 130))
            device.angle = HingeAngle(degrees: to)
        }
        let shared = SharedHinge(inner: inner.hinge, motor: motor)
        let w = shared.watch { _ in }

        try shared.fold(to: 0, over: 0.8)

        #expect(shared.angle() == HingeAngle(degrees: 0))
        w.cancel()
    }

    final class Sweeps: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        var log: [String] { lock.withLock { storage } }
        func append(_ entry: String) { lock.withLock { storage.append(entry) } }
        func record(_ event: HingeSweepEvent) {
            switch event {
            case .began(let sweep): append("began \(sweep.from)→\(sweep.to) over \(sweep.duration)")
            case .ended(let delivery): append("ended \(delivery)")
            }
        }
    }

    /// A 3D book shows a sweep baguette plays as commanded rather than
    /// as the guest reads it back, which can be seconds late.
    @Test func `should tell sweep watchers the sweep as the motor plays it, then how it was delivered`() throws {
        let inner = Inner()
        let heard = Sweeps()
        let motor = MockHingeMotor()
        given(motor).fold(from: .any, to: .any, over: .any).willProduce { _, _, _ in heard.append("motor") }
        let shared = SharedHinge(inner: inner.hinge, motor: motor)
        let w = shared.watch { _ in }
        inner.onAngle?(HingeAngle(degrees: 130))
        let sweeps = shared.watchSweeps { heard.record($0) }

        try shared.fold(to: 0, over: 0.8)

        #expect(heard.log == ["began 130.0→0.0 over 0.8", "motor", "ended delivered"])
        sweeps.cancel()
        w.cancel()
    }

    @Test func `should tell sweep watchers a fold the guest refused or did not confirm`() {
        let outcomes: [(HingeError, String)] = [(.toolFailed(status: 1), "rejected"), (.toolTimedOut, "unconfirmed")]
        for (error, delivery) in outcomes {
            let inner = Inner()
            given(inner.hinge).angle().willReturn(HingeAngle(degrees: 130))
            let motor = MockHingeMotor()
            given(motor).fold(from: .any, to: .any, over: .any).willProduce { _, _, _ in throw error }
            let shared = SharedHinge(inner: inner.hinge, motor: motor)
            let heard = Sweeps()
            let sweeps = shared.watchSweeps { heard.record($0) }

            #expect(throws: error) { try shared.fold(to: 0, over: 0.8) }

            #expect(heard.log == ["began 130.0→0.0 over 0.8", "ended \(delivery)"])
            sweeps.cancel()
        }
    }

    @Test func `should tell a cancelled sweep watcher nothing more`() throws {
        let inner = Inner()
        given(inner.hinge).angle().willReturn(HingeAngle(degrees: 130))
        let motor = MockHingeMotor()
        given(motor).fold(from: .any, to: .any, over: .any).willReturn()
        let shared = SharedHinge(inner: inner.hinge, motor: motor)
        let gone = Sweeps(), kept = Sweeps()
        let a = shared.watchSweeps { gone.record($0) }
        let b = shared.watchSweeps { kept.record($0) }
        a.cancel()

        try shared.fold(to: 0, over: 0.8)

        #expect(gone.log.isEmpty)
        #expect(kept.log.count == 2)
        b.cancel()
    }

    /// Two clients folding at once: watchers hear the second sweep begin
    /// only once the first has ended, as the guest plays them.
    @Test func `should play one fold at a time`() {
        let inner = Inner()
        given(inner.hinge).angle().willReturn(nil)
        let heard = Sweeps()
        let motor = MockHingeMotor()
        given(motor).fold(from: .any, to: .any, over: .any).willProduce { _, to, _ in
            heard.append("motor \(to)")
            Thread.sleep(forTimeInterval: 0.05)
        }
        let shared = SharedHinge(inner: inner.hinge, motor: motor)
        let sweeps = shared.watchSweeps { heard.record($0) }

        DispatchQueue.concurrentPerform(iterations: 2) { i in
            try? shared.fold(to: i == 0 ? 0 : 180, over: 0.8)
        }

        let log = heard.log
        #expect(log.count == 6)
        for start in stride(from: 0, to: log.count - 2, by: 3) {
            #expect(log[start].hasPrefix("began"))
            #expect(log[start + 1].hasPrefix("motor"))
            #expect(log[start + 2] == "ended delivered")
        }
        sweeps.cancel()
    }

    @Test func `should keep one shared hinge per device set and device identifier`() {
        let udid = UUID().uuidString
        let a = SharedHinge.forDevice(udid, deviceSetPath: "/sets/a", make: { MockHinge() })
        #expect(a === SharedHinge.forDevice(udid, deviceSetPath: "/sets/a", make: { MockHinge() }))
        #expect(a !== SharedHinge.forDevice(udid, deviceSetPath: "/sets/b", make: { MockHinge() }))
        #expect(a !== SharedHinge.forDevice(udid, make: { MockHinge() }))
    }

    /// The same device always gets the same shared hinge, whoever asks.
    @Test func `should hand out one shared hinge per device`() {
        let inner = Inner()
        let first = SharedHinge.forDevice("duo", make: { inner.hinge })
        let second = SharedHinge.forDevice("duo", make: { MockHinge() })
        #expect(first === second)
        #expect(SharedHinge.forDevice("other", make: { MockHinge() }) !== first)
    }
}
