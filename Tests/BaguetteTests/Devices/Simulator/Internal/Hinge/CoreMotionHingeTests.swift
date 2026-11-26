import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// `CoreMotionHinge` reads the hinge with `CoreMotionAngle read-angle` spawned
/// in the guest, which prints the current angle and exits, and watches
/// it with `watch-angle`, which prints every sample until stopped. The
/// orchestration is: spawn, split lines, take the first sample,
/// terminate — and give up on exit or after a deadline. All of that is
/// driven here through `MockSubprocess`; the `Foundation.Process`
/// plumbing is integration-only.
@Suite("CoreMotionHinge — orchestration via Subprocess")
struct CoreMotionHingeTests {

    final class Captures: @unchecked Sendable {
        var executable: URL?
        var arguments: [String]?
        var onBytes: (@Sendable (Data) -> Void)?
        var onExit: (@Sendable (Int32) -> Void)?
    }

    private let sample = "angle 130\n"
    private let diagnostic = "CoreMotion: some guest diagnostic\n"

    /// `feed` runs inside the spawn, before `angle()` starts waiting —
    /// which is how a real child that answers instantly behaves too.
    private func makeHinge(
        deviceSetPath: String? = nil,
        path: String? = "/tools/CoreMotionAngle",
        feed: @escaping @Sendable (Captures) -> Void
    ) -> (CoreMotionHinge, MockSubprocess, Captures) {
        let sub = MockSubprocess()
        let captures = Captures()
        given(sub).run(
            executable: .any, arguments: .any, onBytes: .any, onExit: .any
        ).willProduce { exe, args, onBytes, onExit in
            captures.executable = exe
            captures.arguments = args
            captures.onBytes = onBytes
            captures.onExit = onExit
            feed(captures)
        }
        given(sub).terminate().willReturn()
        let hinge = CoreMotionHinge(
            udid: "duo", deviceSetPath: deviceSetPath, subprocess: { sub }, path: { path }, deadline: 0.5)
        return (hinge, sub, captures)
    }

    /// Sweeps are played through `SharedHinge`'s motor; the reader
    /// hears only the guest's samples.
    @Test func `should hear of no sweeps, since it only reads`() {
        let (hinge, sub, _) = makeHinge { _ in }
        let watch = hinge.watchSweeps { _ in Issue.record("a reader heard a sweep") }
        watch.cancel()
        verify(sub).run(executable: .any, arguments: .any, onBytes: .any, onExit: .any).called(0)
    }

    @Test func `should read this device's hinge with CoreMotionAngle in the guest`() {
        let (hinge, _, captures) = makeHinge { c in c.onBytes?(Data(self.sample.utf8)) }
        _ = hinge.angle()
        #expect(captures.executable?.path == "/usr/bin/xcrun")
        #expect(captures.arguments == ["simctl", "spawn", "duo", "/tools/CoreMotionAngle", "read-angle"])
    }

    @Test func `should read the hinge of a device in a custom set`() {
        let (hinge, _, captures) = makeHinge(deviceSetPath: "/sets/a") { c in c.onBytes?(Data(self.sample.utf8)) }
        _ = hinge.angle()
        #expect(captures.arguments == ["simctl", "--set", "/sets/a", "spawn", "duo", "/tools/CoreMotionAngle", "read-angle"])
    }

    @Test func `should read the hinge angle from the first sample`() {
        let (hinge, _, _) = makeHinge { c in c.onBytes?(Data((self.diagnostic + self.sample).utf8)) }
        #expect(hinge.angle() == HingeAngle(degrees: 130))
    }

    /// One sample is all that is needed, so the child is stopped as soon
    /// as it lands rather than left to exit on its own.
    @Test func `should stop the reader once a sample has landed`() {
        let (hinge, sub, _) = makeHinge { c in c.onBytes?(Data(self.sample.utf8)) }
        _ = hinge.angle()
        verify(sub).terminate().called(1)
    }

    /// Output arrives in whatever chunks the pipe delivers; a sample
    /// split across two of them is still one sample.
    @Test func `should reassemble a sample split across chunks`() {
        let (hinge, _, _) = makeHinge { c in
            c.onBytes?(Data("ang".utf8))
            c.onBytes?(Data("le 130\n".utf8))
        }
        #expect(hinge.angle() == HingeAngle(degrees: 130))
    }

    /// The pipe and the exit are separate handlers, so a reader that
    /// printed its sample and exited can be heard exiting first.
    @Test func `should read the angle when the reader's output lands after its exit`() {
        let (hinge, _, _) = makeHinge { c in
            c.onExit?(0)
            c.onBytes?(Data(self.sample.utf8))
        }
        #expect(hinge.angle() == HingeAngle(degrees: 130))
    }

    /// A device without a hinge makes the reader exit without a sample;
    /// that is "no reading", not a crash and not a stale number.
    @Test func `should report no reading when the reader exits before any sample`() {
        let (hinge, _, _) = makeHinge { c in
            c.onBytes?(Data("no hinge on this device\n".utf8))
            c.onExit?(1)
        }
        #expect(hinge.angle() == nil)
    }

    /// A child that never answers must not hang the caller — this sits
    /// on the path that binds every screen and input on a foldable.
    @Test func `should report no reading and stop the reader when it stays silent past the deadline`() {
        let (hinge, sub, _) = makeHinge { _ in }
        #expect(hinge.angle() == nil)
        verify(sub).terminate().called(1)
    }

    @Test func `should report no reading when the reader cannot be started`() {
        let sub = MockSubprocess()
        given(sub).run(
            executable: .any, arguments: .any, onBytes: .any, onExit: .any
        ).willThrow(NSError(domain: "spawn", code: 1))
        let hinge = CoreMotionHinge(udid: "duo", subprocess: { sub }, path: { "/tools/CoreMotionAngle" }, deadline: 0.5)
        #expect(hinge.angle() == nil)
    }

    @Test func `should report no reading without spawning when CoreMotionAngle is missing`() {
        let (hinge, sub, _) = makeHinge(path: nil) { _ in }
        #expect(hinge.angle() == nil)
        verify(sub).run(executable: .any, arguments: .any, onBytes: .any, onExit: .any).called(0)
    }

    // MARK: - watch

    /// Device Hub animates a pose change as a 0.5–0.85 s sweep of
    /// samples at 60 Hz (measured: 3.8° → 130° in 0.84 s, ease-out).
    /// A watch hands every sample on, in order, for as long as it runs.
    @Test func `should deliver every sample of a watch in order`() {
        final class Seen: @unchecked Sendable { var angles: [Double] = [] }
        let seen = Seen()
        let (hinge, _, captures) = makeHinge { _ in }
        let watch = hinge.watch { seen.angles.append($0.degrees) }
        captures.onBytes?(Data((diagnostic + "angle 3.8\nangle 16.2\n").utf8))
        captures.onBytes?(Data("angle 88.2\n".utf8))
        #expect(seen.angles == [3.8, 16.2, 88.2])
        watch.cancel()
    }

    @Test func `should watch this device's hinge with CoreMotionAngle in the guest`() {
        let (hinge, _, captures) = makeHinge(deviceSetPath: "/sets/a") { _ in }
        let watch = hinge.watch { _ in }
        #expect(captures.arguments == ["simctl", "--set", "/sets/a", "spawn", "duo", "/tools/CoreMotionAngle", "watch-angle"])
        watch.cancel()
    }

    @Test func `should stop the watcher when a watch is cancelled`() {
        let (hinge, sub, _) = makeHinge { _ in }
        let watch = hinge.watch { _ in }
        watch.cancel()
        verify(sub).terminate().called(1)
    }

    /// Nothing after cancel: a sample the pipe still had buffered must
    /// not reach a caller that has moved on.
    @Test func `should drop late samples when the watch is cancelled`() {
        final class Seen: @unchecked Sendable { var count = 0 }
        let seen = Seen()
        let (hinge, _, captures) = makeHinge { _ in }
        let watch = hinge.watch { _ in seen.count += 1 }
        watch.cancel()
        captures.onBytes?(Data(sample.utf8))
        #expect(seen.count == 0)
    }

    @Test func `should deliver nothing when watching a device without a hinge`() {
        final class Seen: @unchecked Sendable { var count = 0 }
        let seen = Seen()
        let (hinge, _, captures) = makeHinge { _ in }
        let watch = hinge.watch { _ in seen.count += 1 }
        captures.onBytes?(Data("no hinge on this device\n".utf8))
        captures.onExit?(1)
        #expect(seen.count == 0)
        watch.cancel()
    }

    @Test func `should deliver nothing without spawning when watching without CoreMotionAngle`() {
        let (hinge, sub, _) = makeHinge(path: nil) { _ in }
        let watch = hinge.watch { _ in Issue.record("no sample expected") }
        watch.cancel()
        verify(sub).run(executable: .any, arguments: .any, onBytes: .any, onExit: .any).called(0)
    }
}
