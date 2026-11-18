import CoreVideo
import Foundation
import Mockable
import Testing
@testable import BaguetteDevice

/// What the device-twin's H.264 decoder decides, with VideoToolbox's
/// decompression session mocked: which avcC records it accepts, which
/// parameter sets its session opens with, and which pictures it hands on.
@Suite("VTH264Decoder")
struct VTH264DecoderTests {

    private let sps = Data([0x67, 0x64, 0x00, 0x1F])
    private let pps = Data([0x68, 0xEE])

    /// An avcC record with this NALU prefix length, holding `sps` and `pps`.
    private var description: Data {
        var bytes: [UInt8] = [1, 0x64, 0x00, 0x1F, 0xFC | 0x01, 0xE1, 0, UInt8(sps.count)]
        bytes += sps
        bytes += [1, 0, UInt8(pps.count)]
        bytes += pps
        return Data(bytes)
    }

    private func session(
        opening refusal: DecompressionRefusal? = nil,
        answer: @escaping @Sendable () -> DecompressionResult = { DecompressionResult(status: 0, picture: Pictures.surfaceBacked()) }
    ) -> MockDecompressionSession {
        let session = MockDecompressionSession()
        given(session).open(parameterSets: .any, nalUnitHeaderLength: .any, croppedTo: .any).willReturn(refusal)
        given(session).decode(.any, asynchronously: .any, done: .any).willProduce { _, _, done in done(answer()) }
        given(session).close().willReturn()
        return session
    }

    @Test func `should open its session from the record's first SPS and PPS and its prefix length`() throws {
        let session = session()
        let decoder = VTH264Decoder(session: session)

        try decoder.configure(description: description) { _ in }

        verify(session).open(parameterSets: .value([sps, pps]), nalUnitHeaderLength: .value(2), croppedTo: .value(nil))
            .called(1)
    }

    @Test func `should refuse a description that is not an avcC record`() {
        let session = session()
        let decoder = VTH264Decoder(session: session)

        #expect(throws: VTH264Decoder.DecoderError.self) {
            try decoder.configure(description: Data([0, 1, 2])) { _ in }
        }
        verify(session).open(parameterSets: .any, nalUnitHeaderLength: .any, croppedTo: .any).called(0)
    }

    @Test func `should refuse a record whose parameter sets describe no picture`() {
        let decoder = VTH264Decoder(session: session(opening: .format(-12712)))

        #expect {
            try decoder.configure(description: description) { _ in }
        } throws: { error in
            if case VTH264Decoder.DecoderError.formatRejected(-12712) = error { true } else { false }
        }
    }

    @Test func `should refuse a record whose session cannot be opened`() {
        let decoder = VTH264Decoder(session: session(opening: .session(-12903)))

        #expect {
            try decoder.configure(description: description) { _ in }
        } throws: { error in
            if case VTH264Decoder.DecoderError.sessionRejected(-12903) = error { true } else { false }
        }
    }

    @Test func `should hand each decoded picture's surface on, decoding off the caller's thread`() throws {
        let session = session()
        let decoder = VTH264Decoder(session: session)
        let surfaces = Delivered()
        try decoder.configure(description: description) { surfaces.append($0) }

        decoder.decode(Data([0, 1, 0x65]))

        #expect(surfaces.count == 1)
        verify(session).decode(.value(Data([0, 1, 0x65])), asynchronously: .value(true), done: .any).called(1)
    }

    @Test func `should hand on no surface when a picture is not surface-backed`() throws {
        let decoder = VTH264Decoder(session: session { DecompressionResult(status: 0, picture: Pictures.inMemory()) })
        let surfaces = Delivered()
        try decoder.configure(description: description) { surfaces.append($0) }

        decoder.decode(Data([1]))
        decoder.decode(Data([1]))

        #expect(surfaces.count == 0)
    }

    @Test func `should decode nothing before it is configured`() {
        let session = session()
        let decoder = VTH264Decoder(session: session)

        decoder.decode(Data([1]))

        verify(session).decode(.any, asynchronously: .any, done: .any).called(0)
    }

    @Test func `should decode nothing once stopped`() throws {
        let session = session()
        let decoder = VTH264Decoder(session: session)
        try decoder.configure(description: description) { _ in }

        decoder.stop()
        decoder.decode(Data([1]))

        verify(session).close().called(1)
        verify(session).decode(.any, asynchronously: .any, done: .any).called(0)
    }
}
