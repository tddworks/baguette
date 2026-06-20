import Testing
import Foundation
@testable import BaguetteCore

@Suite("BGRAConverter")
struct BGRAConverterTests {

    @Test func `passes through a tightly packed buffer`() throws {
        // 2×2 BGRA: 4 pixels × 4 bytes = 16 bytes. bytesPerRow == width*4.
        let raw = Data([0x11, 0x22, 0x33, 0xFF,  0x44, 0x55, 0x66, 0xFF,
                        0x77, 0x88, 0x99, 0xFF,  0xAA, 0xBB, 0xCC, 0xFF])
        let frame = try raw.withUnsafeBytes { ptr in
            try BGRAConverter.convert(
                baseAddress: ptr.baseAddress!,
                width: 2, height: 2,
                bytesPerRow: 8,
                sequence: 7, timestampMs: 42
            )
        }
        #expect(frame.pixels == raw)
        #expect(frame.sequence == 7)
        #expect(frame.timestampMs == 42)
        #expect(frame.width == 2)
        #expect(frame.height == 2)
    }

    @Test func `strips trailing row padding when bytesPerRow exceeds width times four`() throws {
        // 2×2 with bytesPerRow == 12 (8 pixel bytes + 4 padding).
        // Row 0: 11 22 33 FF | 44 55 66 FF | <pad>00 00 00 00
        // Row 1: 77 88 99 FF | AA BB CC FF | <pad>00 00 00 00
        let strided = Data([
            0x11, 0x22, 0x33, 0xFF,  0x44, 0x55, 0x66, 0xFF,  0x00, 0x00, 0x00, 0x00,
            0x77, 0x88, 0x99, 0xFF,  0xAA, 0xBB, 0xCC, 0xFF,  0x00, 0x00, 0x00, 0x00,
        ])
        let frame = try strided.withUnsafeBytes { ptr in
            try BGRAConverter.convert(
                baseAddress: ptr.baseAddress!,
                width: 2, height: 2,
                bytesPerRow: 12,
                sequence: 1, timestampMs: 0
            )
        }
        let expectedPacked = Data([0x11, 0x22, 0x33, 0xFF,  0x44, 0x55, 0x66, 0xFF,
                                   0x77, 0x88, 0x99, 0xFF,  0xAA, 0xBB, 0xCC, 0xFF])
        #expect(frame.pixels == expectedPacked)
    }
}
