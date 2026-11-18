import Foundation
import Testing
@testable import Baguette

@Suite("TwinPoses")
struct TwinPosesTests {
    private let sample = AttitudeSample(
        attitude: Attitude(x: 0, y: 0, z: 0.259, w: 0.966), timestamp: 1
    )

    final class Recorder: @unchecked Sendable {
        var samples: [AttitudeSample] = []
        func record(_ s: AttitudeSample) { samples.append(s) }
    }

    @Test func `should deliver an attitude update to every subscriber of that device`() {
        let poses = TwinPoses()
        let first = Recorder()
        let second = Recorder()
        poses.subscribe(udid: "U1", id: "a") { first.record($0) }
        poses.subscribe(udid: "U1", id: "b") { second.record($0) }
        poses.update(udid: "U1", sample: sample)
        #expect(first.samples.count == 1)
        #expect(second.samples.count == 1)
    }

    @Test func `should never deliver one device's updates to another device's subscribers`() {
        let poses = TwinPoses()
        let other = Recorder()
        poses.subscribe(udid: "U2", id: "a") { other.record($0) }
        poses.update(udid: "U1", sample: sample)
        #expect(other.samples.isEmpty)
    }

    @Test func `should give a late subscriber the latest sample right away`() {
        let poses = TwinPoses()
        poses.update(udid: "U1", sample: sample)
        let late = Recorder()
        poses.subscribe(udid: "U1", id: "a") { late.record($0) }
        #expect(late.samples.count == 1)
    }

    @Test func `should stop delivering only to the subscriber that unsubscribes`() {
        let poses = TwinPoses()
        let kept = Recorder()
        let dropped = Recorder()
        poses.subscribe(udid: "U1", id: "keep") { kept.record($0) }
        poses.subscribe(udid: "U1", id: "drop") { dropped.record($0) }
        poses.unsubscribe(udid: "U1", id: "drop")
        poses.update(udid: "U1", sample: sample)
        #expect(kept.samples.count == 1)
        #expect(dropped.samples.isEmpty)
    }

    @Test func `should forget a device's latest sample when it is cleared`() {
        let poses = TwinPoses()
        poses.update(udid: "U1", sample: sample)
        poses.clear(udid: "U1")
        let late = Recorder()
        poses.subscribe(udid: "U1", id: "a") { late.record($0) }
        #expect(late.samples.isEmpty)
    }
}
