import Foundation
import Testing
@testable import Baguette

/// The emulator control API's messages, as protobuf bytes on the wire — the
/// handful baguette sends and reads (android.emulation.control, emulator 37).
@Suite("EmulatorControl")
struct EmulatorControlTests {
    @Test func `should ask for pictures as RGBA pixels`() {
        #expect(EmulatorControl.ImageFormat(format: .rgba8888).bytes == Data([0x08, 0x01]))
    }

    @Test func `should put a finger on the screen at its point, by its identifier`() {
        let event = EmulatorControl.TouchEvent(touches: [.init(x: 540, y: 1200, identifier: 1, pressure: 1)])

        #expect(event.bytes == Data([0x0A, 0x0A, 0x08, 0x9C, 0x04, 0x10, 0xB0, 0x09, 0x18, 0x01, 0x20, 0x01]))
    }

    @Test func `should lift a finger by sending it with no pressure`() {
        let event = EmulatorControl.TouchEvent(touches: [.init(x: 540, y: 1200, identifier: 1, pressure: 0)])

        #expect(event.bytes == Data([0x0A, 0x08, 0x08, 0x9C, 0x04, 0x10, 0xB0, 0x09, 0x18, 0x01]))
    }

    @Test func `should send two fingers as two touches`() {
        let event = EmulatorControl.TouchEvent(touches: [.init(x: 1, y: 2, identifier: 1, pressure: 1),
                                                      .init(x: 3, y: 4, identifier: 2, pressure: 1)])

        #expect(event.bytes == Data([0x0A, 0x08, 0x08, 0x01, 0x10, 0x02, 0x18, 0x01, 0x20, 0x01,
                                     0x0A, 0x08, 0x08, 0x03, 0x10, 0x04, 0x18, 0x02, 0x20, 0x01]))
    }

    @Test func `should press a key by its USB HID usage`() {
        #expect(EmulatorControl.KeyboardEvent(usage: 0x04, kind: .press).bytes == Data([0x10, 0x02, 0x18, 0x04]))
        #expect(EmulatorControl.KeyboardEvent(usage: 0x04, kind: .down).bytes == Data([0x18, 0x04]))
    }

    @Test func `should read a picture's size and pixels from the emulator's image`() throws {
        // Image { format: { format: RGBA8888, width: 2, height: 1 }, image: 8 bytes, seq: 7 }
        let bytes = Data([0x0A, 0x06, 0x08, 0x01, 0x18, 0x02, 0x20, 0x01,
                          0x22, 0x08, 1, 2, 3, 4, 5, 6, 7, 8,
                          0x28, 0x07])

        let image = try #require(EmulatorControl.Image(bytes))

        #expect(image.width == 2)
        #expect(image.height == 1)
        #expect(image.pixels == Data([1, 2, 3, 4, 5, 6, 7, 8]))
        #expect(image.sequence == 7)
    }

    @Test func `should read no picture from bytes that aren't an image`() {
        #expect(EmulatorControl.Image(Data([0xFF, 0xFF, 0xFF])) == nil)
    }
}
