import Testing
import Foundation
@testable import BaguetteCore

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

        let pixels = Data([0x11, 0x22, 0x33, 0xFF,  0x44, 0x55, 0x66, 0xFF,
                           0x77, 0x88, 0x99, 0xFF,  0xAA, 0xBB, 0xCC, 0xFF])
        let frame = try CameraFrame(
            sequence: 0x01020304,
            timestampMs: 0x05060708,
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
}
