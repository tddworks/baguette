import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

@Suite("SharedFrameLayout")
struct SharedFrameLayoutTests {
    @Test func `should give the shared frame a 24-byte header`() {
        #expect(SharedFrameLayout.headerSize == 24)
    }

    @Test func `should cap the shared canvas at the virtual camera reader's 1280 by 1280`() {
        // VirtualCamera/Sources/SharedFrameReader.m: kMaxCanvas = 1280.
        // A mismatch here means the reader would reject our frames.
        #expect(SharedFrameLayout.maxCanvasWidth == 1280)
        #expect(SharedFrameLayout.maxCanvasHeight == 1280)
    }

    @Test func `should size the shared frame as the header plus a 1280 by 1280 BGRA canvas`() {
        // 24 + 1280 * 1280 * 4 = 6_553_624 bytes.
        #expect(SharedFrameLayout.totalByteCount == 24 + 1280 * 1280 * 4)
    }

    @Test func `should write the frame header fields little-endian at their documented offsets`() {
        let header = SharedFrameLayout.encodeHeader(
            sequence: 0x0A0B0C0D,
            timestampMs: 0x11223344,
            width: 720,
            height: 1280,
            flags: 0b11
        )
        #expect(header.count == 24)
        // sequence at [0..<4]
        #expect(header[0..<4] == [0x0D, 0x0C, 0x0B, 0x0A])
        // timestampMs at [4..<8]
        #expect(header[4..<8] == [0x44, 0x33, 0x22, 0x11])
        // width at [8..<12] = 720 = 0x2D0
        #expect(header[8..<12] == [0xD0, 0x02, 0x00, 0x00])
        // height at [12..<16] = 1280 = 0x500
        #expect(header[12..<16] == [0x00, 0x05, 0x00, 0x00])
        // flags at [16..<20]
        #expect(header[16..<20] == [0x03, 0x00, 0x00, 0x00])
        // reserved at [20..<24] is zero
        #expect(header[20..<24] == [0x00, 0x00, 0x00, 0x00])
    }
}
