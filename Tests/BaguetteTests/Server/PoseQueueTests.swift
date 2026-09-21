import Foundation
import Testing
import Mockable
@testable import Baguette

// A socket's `set_pose` requests: a slider drag sends a burst, and the
// hinge should catch up to the thumb rather than replay its path.
@Suite("PoseQueue")
struct PoseQueueTests {
    @Test func `a burst plays the request under way and the newest, skipping the ones between`() async {
        let queue = PoseQueue()
        let started = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let played = Played()
        queue.enqueue { started.signal(); gate.wait(); played.add(1) }
        blockUntil(started)
        queue.enqueue { played.add(2) }
        queue.enqueue { played.add(3) }
        gate.signal()
        await queue.settled()
        #expect(played.values == [1, 3])
    }
}

// `set_pose` rides both sockets — the flat stream's fold bar and the 3D
// book's pose picker — and moves the device's own hinge.
@Suite("Server pose request")
struct ServerPoseRequestTests {
    private func wiring() -> (MockSimulators, MockHinge) {
        let host = MockSimulators(), sim = MockSimulator(), hinge = MockHinge()
        given(host).find(udid: .value("U")).willReturn(sim)
        given(sim).hinge().willReturn(hinge)
        given(hinge).fold(to: .any, over: .any).willReturn()
        return (host, hinge)
    }

    @Test func `a set_pose line folds the hinge there`() async throws {
        let (host, hinge) = wiring()
        let poses = PoseQueue()
        let line = #"{"type":"set_pose","hingeDegrees":130}"#
        #expect(try Server.queuePose(line: line, udid: "U", simulators: host, poses: poses))
        await poses.settled()
        verify(hinge).fold(to: .value(130), over: .value(HingeCommand.defaultDuration)).called(1)
    }

    @Test func `the slider's zero duration puts the hinge straight there`() async throws {
        let (host, hinge) = wiring()
        let poses = PoseQueue()
        let line = #"{"type":"set_pose","hingeDegrees":72.5,"duration":0}"#
        #expect(try Server.queuePose(line: line, udid: "U", simulators: host, poses: poses))
        await poses.settled()
        verify(hinge).fold(to: .value(72.5), over: .value(0)).called(1)
    }

    @Test func `any other line is left for the gesture pipeline`() async throws {
        let (host, hinge) = wiring()
        let poses = PoseQueue()
        #expect(try Server.queuePose(line: #"{"type":"tap","x":1,"y":2}"#, udid: "U", simulators: host, poses: poses) == false)
        await poses.settled()
        verify(hinge).fold(to: .any, over: .any).called(0)
    }

    @Test func `an angle off the hinge is refused`() {
        let (host, _) = wiring()
        #expect(throws: DeviceModelError.invalidRenderOptions) {
            _ = try Server.queuePose(
                line: #"{"type":"set_pose","hingeDegrees":200}"#, udid: "U", simulators: host, poses: PoseQueue())
        }
    }
}

private func blockUntil(_ semaphore: DispatchSemaphore) { semaphore.wait() }

private final class Played: @unchecked Sendable {
    private let lock = NSLock()
    private var played: [Int] = []
    func add(_ n: Int) { lock.withLock { played.append(n) } }
    var values: [Int] { lock.withLock { played } }
}
