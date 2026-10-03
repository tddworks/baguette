import Foundation
import Testing

@testable import Baguette

@Suite("SharedMemoryFrameSink")
struct SharedMemoryFrameSinkTests {

    private func tmpPath() -> String {
        let dir = NSTemporaryDirectory()
        return (dir as NSString).appendingPathComponent("baguette-fs-\(UUID().uuidString).bgra")
    }

    @Test func `write lays the header and pixels into the mmapped file`() throws {
        let path = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let sink = try SharedMemoryFrameSink(path: path)

        let pixels = Data([
            0x11, 0x22, 0x33, 0xFF, 0x44, 0x55, 0x66, 0xFF,
            0x77, 0x88, 0x99, 0xFF, 0xAA, 0xBB, 0xCC, 0xFF,
        ])
        let frame = try CameraFrame(
            sequence: 0x0102_0304,
            timestampMs: 0x0506_0708,
            width: 2, height: 2,
            pixels: pixels
        )
        try sink.write(frame, flags: CameraFlags(fillGravity: true, mirror: false))

        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        // Sequence at [0..<4], little-endian.
        #expect(bytes[0..<4] == Data([0x04, 0x03, 0x02, 0x01]))
        // Width at [8..<12].
        #expect(bytes[8..<12] == Data([0x02, 0x00, 0x00, 0x00]))
        // Flags at [16..<20] — fillGravity only, bit 0.
        #expect(bytes[16..<20] == Data([0x01, 0x00, 0x00, 0x00]))
        // Pixels at [24..<24+16].
        #expect(bytes[24..<40] == pixels)
    }

    @Test func `path exposes the on-disk location`() throws {
        let path = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let sink = try SharedMemoryFrameSink(path: path)
        #expect(sink.path == path)
    }

    @Test func `a second producer cannot overwrite a live camera frame`() throws {
        let path = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        var sink: SharedMemoryFrameSink? = try SharedMemoryFrameSink(path: path)
        let frame = try CameraFrame(
            sequence: 42, timestampMs: 0, width: 1, height: 1,
            pixels: Data([1, 2, 3, 255]))
        try sink?.write(frame, flags: CameraFlags())
        #expect(throws: (any Error).self) { try SharedMemoryFrameSink(path: path) }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path))[0] == 42)
        sink = nil
        let replacement = try SharedMemoryFrameSink(path: path)
        try replacement.write(frame, flags: CameraFlags())
    }
}
