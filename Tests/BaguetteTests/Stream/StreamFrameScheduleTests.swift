import Foundation
import Testing

@testable import Baguette

@Suite("StreamFrameSchedule")
struct StreamFrameScheduleTests {
    @Test func `bursts keep the latest frame and flush it after the source goes quiet`() {
        var schedule = StreamFrameSchedule<Int>(fps: 30, repeating: false)
        schedule.offer(1)
        #expect(schedule.deadline(at: 0) == 0)
        let first = schedule.take(at: 0)
        schedule.offer(2)
        schedule.offer(3)
        #expect(schedule.deadline(at: 0.01) == 1.0 / 30)
        let early = schedule.take(at: 0.02)
        let last = schedule.take(at: 1.0 / 30)
        #expect(first == 1 && early == nil && last == 3)
        #expect(schedule.deadline(at: 1) == nil)
    }

    @Test func `60 Hz arrivals produce at most the requested 30 frames per second`() {
        var schedule = StreamFrameSchedule<Int>(fps: 30, repeating: false)
        var emitted: [Int] = []
        for index in 0...60 {
            let now = Double(index) / 60
            schedule.offer(index)
            if let frame = schedule.take(at: now) { emitted.append(frame) }
        }
        if let deadline = schedule.deadline(at: 1), let frame = schedule.take(at: deadline) { emitted.append(frame) }
        #expect(emitted.first == 0 && emitted.last == 60)
        #expect(emitted.count <= 32)
        #expect(emitted.count >= 25)
    }

    @Test func `runtime fps changes reschedule both pending and idle frames`() {
        var schedule = StreamFrameSchedule<Int>(fps: 30, repeating: true)
        schedule.offer(7)
        let first = schedule.take(at: 0)
        #expect(first == 7)
        schedule.fps = 60
        #expect(schedule.deadline(at: 0.01) == 1.0 / 60)
        let idle = schedule.take(at: 1.0 / 60)
        #expect(idle == 7)
        schedule.offer(9)
        schedule.fps = 30
        #expect(schedule.deadline(at: 0.02) == 1.0 / 60 + 1.0 / 30)
        let recent = schedule.take(at: 1.0 / 60 + 1.0 / 30)
        #expect(recent == 9)
        schedule.clear()
        #expect(schedule.deadline(at: 2) == nil)
        let stopped = schedule.take(at: 2)
        #expect(stopped == nil)
    }

    @Test func `AVCC keeps references while MJPEG can discard complete old frames`() {
        var avcc = FrameBacklog(format: .avcc)
        let half = Data(repeating: 0x02, count: FrameBacklog.referenceByteBudget / 2)
        let first = avcc.append(half)
        let second = avcc.append(half)
        let overflow = avcc.append(Data([0x02]))
        #expect(first && second && !overflow)
        #expect(avcc.droppedCount == 0 && avcc.count == 2)
        var jpeg = FrameBacklog(format: .mjpeg)
        let image = Data(repeating: 0xFF, count: FrameBacklog.defaultByteBudget)
        jpeg.append(image)
        jpeg.append(Data([0xFF, 0xD8]))
        #expect(jpeg.count == 1 && jpeg.droppedCount == 1)
    }

    @Test func `scheduled delivery retains the final pending frame and stop cancels idle repeats`() throws {
        let values = PacedValues()
        let queue = DispatchQueue(label: "frame-pump-test")
        let pump = StreamFramePump<Int>(queue: queue, fps: 20, repeating: true) { values.append($0) }
        pump.start()
        pump.offer(1)
        #expect(values.changed.wait(timeout: .now() + 1) == .success)
        pump.offer(2)
        pump.offer(3)
        #expect(values.changed.wait(timeout: .now() + 1) == .success)
        pump.stop()
        #expect(values.values.prefix(2) == [1, 3])
        let stoppedCount = values.values.count
        pump.offer(4)
        let deadline = DispatchSemaphore(value: 0)
        queue.asyncAfter(deadline: .now() + 0.1) { deadline.signal() }
        #expect(deadline.wait(timeout: .now() + 1) == .success)
        #expect(values.values.count == stoppedCount)
    }
}

private final class PacedValues: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []
    let changed = DispatchSemaphore(value: 0)
    var values: [Int] { lock.withLock { storage } }
    func append(_ value: Int) {
        lock.withLock { storage.append(value) }
        changed.signal()
    }
}
