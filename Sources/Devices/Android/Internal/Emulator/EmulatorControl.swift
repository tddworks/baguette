import Foundation
import IOSurface

/// The Android Emulator's control API (`android.emulation.control`, served
/// over gRPC) — the handful of its protobuf messages baguette sends and
/// reads, encoded by hand: field numbers from Google's
/// `emulator_controller.proto`, proto3, so a field at its default (0) is
/// left out. Design: docs/features/android/design.md.
enum EmulatorControl {
    /// What kind of picture `getScreenshot` / `streamScreenshot` hand back.
    struct ImageFormat: Equatable, Sendable {
        enum Format: UInt64, Sendable { case png = 0, rgba8888 = 1, rgb888 = 2 }
        let format: Format

        var bytes: Data { Protobuf.varint(field: 1, format.rawValue) }
    }

    /// Fingers on the screen, each by its `identifier` (a multitouch slot);
    /// a finger with no pressure is lifted.
    struct TouchEvent: Equatable, Sendable {
        struct Touch: Equatable, Sendable {
            let x: Int
            let y: Int
            let identifier: Int
            let pressure: Int
        }
        let touches: [Touch]

        var bytes: Data {
            touches.reduce(into: Data()) { out, touch in
                out += Protobuf.message(field: 1,
                                        Protobuf.varint(field: 1, Protobuf.int32(touch.x))
                                        + Protobuf.varint(field: 2, Protobuf.int32(touch.y))
                                        + Protobuf.varint(field: 3, Protobuf.int32(touch.identifier))
                                        + Protobuf.varint(field: 4, Protobuf.int32(touch.pressure)))
            }
        }
    }

    /// A picture of the screen: its size (in its format) and its pixels.
    struct Image: Equatable, Sendable {
        let width: Int
        let height: Int
        let pixels: Data
        let sequence: Int

        init?(_ bytes: Data) {
            guard let fields = Protobuf.fields(bytes) else { return nil }
            let format = fields.first { $0.number == 1 }.flatMap { $0.bytes.flatMap(Protobuf.fields) } ?? []
            guard let pixels = fields.first(where: { $0.number == 4 })?.bytes else { return nil }
            width = Int(format.first { $0.number == 3 }?.varint ?? 0)
            height = Int(format.first { $0.number == 4 }?.varint ?? 0)
            self.pixels = pixels
            sequence = Int(fields.first { $0.number == 5 }?.varint ?? 0)
        }

        /// The picture as every `Screen` hands one on: a BGRA surface — the
        /// emulator's RGBA with red and blue swapped. Nil when its pixels
        /// don't fill its size.
        func bgraSurface() -> IOSurface? {
            let bytesPerRow = width * 4
            guard width > 0, height > 0, pixels.count >= bytesPerRow * height,
                  let surface = IOSurface(properties: [.width: width, .height: height, .bytesPerElement: 4,
                                                       .bytesPerRow: bytesPerRow, .pixelFormat: 0x4247_5241])
            else { return nil }
            surface.lock(options: [], seed: nil)
            defer { surface.unlock(options: [], seed: nil) }
            let rowStride = surface.bytesPerRow
            let out = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
            pixels.withUnsafeBytes { raw in
                let rgba = raw.bindMemory(to: UInt8.self)
                for row in 0..<height {
                    for column in 0..<width {
                        let from = row * bytesPerRow + column * 4, to = row * rowStride + column * 4
                        out[to] = rgba[from + 2]
                        out[to + 1] = rgba[from + 1]
                        out[to + 2] = rgba[from]
                        out[to + 3] = rgba[from + 3]
                    }
                }
            }
            return surface
        }
    }
    /// Just enough protobuf: varint and length-delimited fields, written and read.
    enum Protobuf {
        struct Field: Equatable {
            let number: Int
            let varint: UInt64?
            let bytes: Data?
        }

        /// A varint field; nothing at its default, 0.
        /// An `int32` as protobuf writes it: a negative one sign-extended
        /// to ten bytes, never a trap.
        static func int32(_ value: Int) -> UInt64 {
            UInt64(bitPattern: Int64(Int32(clamping: value)))
        }

        static func varint(field: Int, _ value: UInt64) -> Data {
            value == 0 ? Data() : encode(UInt64(field << 3)) + encode(value)
        }

        /// A length-delimited field (an embedded message, bytes, a string).
        static func message(field: Int, _ body: Data) -> Data {
            encode(UInt64(field << 3 | 2)) + encode(UInt64(body.count)) + body
        }

        /// Every field in `data`, or nil when it isn't protobuf this reads.
        static func fields(_ data: Data) -> [Field]? {
            var index = data.startIndex
            var fields: [Field] = []
            while index < data.endIndex {
                guard let key = decode(data, &index) else { return nil }
                switch key & 7 {
                case 0:
                    guard let value = decode(data, &index) else { return nil }
                    fields.append(Field(number: Int(key >> 3), varint: value, bytes: nil))
                case 2:
                    guard let length = decode(data, &index), length <= UInt64(data.endIndex - index) else { return nil }
                    let end = index + Int(length)
                    fields.append(Field(number: Int(key >> 3), varint: nil, bytes: Data(data[index..<end])))
                    index = end
                default:
                    return nil
                }
            }
            return fields
        }

        static func encode(_ value: UInt64) -> Data {
            var value = value
            var out = Data()
            while value >= 0x80 {
                out.append(UInt8(value & 0x7F) | 0x80)
                value >>= 7
            }
            out.append(UInt8(value))
            return out
        }

        private static func decode(_ data: Data, _ index: inout Data.Index) -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while index < data.endIndex, shift < 64 {
                let byte = data[index]
                index += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
    }
}
