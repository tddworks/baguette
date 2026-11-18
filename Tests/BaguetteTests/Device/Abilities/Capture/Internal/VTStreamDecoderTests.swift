import CoreVideo
import Foundation
import IOSurface
import Mockable
import Testing
@testable import BaguetteDevice

/// What the stream decoder decides, with VideoToolbox's decompression
/// session mocked: whether a picture is cropped to the screen, which
/// frames it decodes, which pictures it keeps alive and hands on.
@Suite("VTStreamDecoder")
struct VTStreamDecoderTests {

    private let sets = [Data([0x67, 0x64, 0x00, 0x1F]), Data([0x68, 0xEE])]

    /// A session whose parameter sets describe `picture`, that opens, and
    /// answers every frame with `answer`.
    private func session(
        picture: Size = Size(width: 1328, height: 2896),
        answer: @escaping @Sendable () -> DecompressionResult = { DecompressionResult(status: 0, picture: Pictures.surfaceBacked()) }
    ) -> MockDecompressionSession {
        let session = MockDecompressionSession()
        given(session).picture(parameterSets: .any, nalUnitHeaderLength: .any).willReturn(.success(picture))
        given(session).open(parameterSets: .any, nalUnitHeaderLength: .any, croppedTo: .any).willReturn(nil)
        given(session).decode(.any, asynchronously: .any, done: .any).willProduce { _, _, done in done(answer()) }
        given(session).close().willReturn()
        return session
    }

    @Test func `should crop its pictures to the screen when the stream pads it`() throws {
        let session = session(picture: Size(width: 1328, height: 2896))
        let decoder = VTStreamDecoder(session: session)

        try decoder.configure(parameterSets: sets, screen: Size(width: 1320, height: 2868)) { _ in }

        let aperture = CleanAperture(screen: Size(width: 1320, height: 2868), picture: Size(width: 1328, height: 2896))
        verify(session).open(parameterSets: .value(sets), nalUnitHeaderLength: .value(4), croppedTo: .value(aperture))
            .called(1)
    }

    @Test func `should keep the whole picture when the screen's size is unknown`() throws {
        let session = session()
        let decoder = VTStreamDecoder(session: session)

        try decoder.configure(parameterSets: sets, screen: nil) { _ in }

        verify(session).open(parameterSets: .any, nalUnitHeaderLength: .any, croppedTo: .value(nil)).called(1)
    }

    @Test func `should refuse parameter sets that describe no picture`() {
        let session = MockDecompressionSession()
        given(session).picture(parameterSets: .any, nalUnitHeaderLength: .any).willReturn(.failure(.format(-12712)))
        let decoder = VTStreamDecoder(session: session)

        #expect(throws: VTStreamDecoder.DecoderError.self) {
            try decoder.configure(parameterSets: sets, screen: nil) { _ in }
        }
        verify(session).open(parameterSets: .any, nalUnitHeaderLength: .any, croppedTo: .any).called(0)
    }

    @Test func `should refuse a stream whose session cannot be opened`() {
        let session = MockDecompressionSession()
        given(session).picture(parameterSets: .any, nalUnitHeaderLength: .any)
            .willReturn(.success(Size(width: 8, height: 8)))
        given(session).open(parameterSets: .any, nalUnitHeaderLength: .any, croppedTo: .any).willReturn(.session(-12903))
        let decoder = VTStreamDecoder(session: session)

        #expect(throws: VTStreamDecoder.DecoderError.self) {
            try decoder.configure(parameterSets: sets, screen: nil) { _ in }
        }
    }

    @Test func `should hand each decoded picture's surface on, decoding in arrival order`() throws {
        let session = session()
        let decoder = VTStreamDecoder(session: session)
        let surfaces = Delivered()
        try decoder.configure(parameterSets: sets, screen: nil) { surfaces.append($0) }

        decoder.decode(Data([0, 0, 0, 1, 0x65]))

        #expect(surfaces.count == 1)
        verify(session).decode(.value(Data([0, 0, 0, 1, 0x65])), asynchronously: .value(false), done: .any).called(1)
    }

    @Test func `should decode nothing before it is configured`() {
        let session = session()
        let decoder = VTStreamDecoder(session: session)

        decoder.decode(Data([1]))

        verify(session).decode(.any, asynchronously: .any, done: .any).called(0)
    }

    @Test func `should skip an empty frame`() throws {
        let session = session()
        let decoder = VTStreamDecoder(session: session)
        try decoder.configure(parameterSets: sets, screen: nil) { _ in }

        decoder.decode(Data())

        verify(session).decode(.any, asynchronously: .any, done: .any).called(0)
    }

    @Test func `should hand on no surface when a frame does not decode`() throws {
        let decoder = VTStreamDecoder(session: session { DecompressionResult(status: -12909, picture: nil) })
        let surfaces = Delivered()
        try decoder.configure(parameterSets: sets, screen: nil) { surfaces.append($0) }

        decoder.decode(Data([1]))
        decoder.decode(Data([1]))

        #expect(surfaces.count == 0)
    }

    @Test func `should keep only the six newest pictures alive for the pipeline to read`() throws {
        let decoder = VTStreamDecoder(session: session())
        try decoder.configure(parameterSets: sets, screen: nil) { _ in }

        for _ in 0..<8 { decoder.decode(Data([1])) }

        #expect(decoder.held == 6)
    }

    @Test func `should let go of every picture and decode nothing once stopped`() throws {
        let session = session()
        let decoder = VTStreamDecoder(session: session)
        try decoder.configure(parameterSets: sets, screen: nil) { _ in }
        decoder.decode(Data([1]))

        decoder.stop()
        decoder.decode(Data([1]))

        #expect(decoder.held == 0)
        verify(session).close().called(1)
        verify(session).decode(.any, asynchronously: .any, done: .any).called(1)
    }
}

/// Pixel buffers like the ones VideoToolbox hands back.
enum Pictures {
    static func surfaceBacked(width: Int = 4, height: Int = 4) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &buffer)
        return buffer!
    }

    static func inMemory() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &buffer)
        return buffer!
    }
}

/// Every surface a decoder handed on.
final class Delivered: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [IOSurface] = []

    func append(_ surface: IOSurface) { lock.withLock { all.append(surface) } }
    var count: Int { lock.withLock { all.count } }
}
