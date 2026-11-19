import Foundation
import IOSurface
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// baguette's own receiver for a phone's screen: our H.264 offer, the
/// phone's RTP made into frames and decoded, our RTCP back — with the
/// decoder stood in for.
@Suite("RTPReceiver")
struct RTPReceiverTests {
    private static let phoneSource: UInt32 = 0xE95D_3647
    private static let ourSource: UInt32 = 7
    nonisolated(unsafe) private static let answer: [String: Any] = ["connection": ["streamConfig": [
        "SourceIP": PhoneJSON.tunnel, "SourcePort": NSNumber(value: 61000),
        "LocalSSRC": NSNumber(value: phoneSource), "RemoteSSRC": NSNumber(value: ourSource),
    ]]]
    private static let screen = Size(width: 1320, height: 2868)

    private static let sps: [UInt8] = [0x67, 0x64, 0x00, 0x33, 0xAC]
    private static let pps: [UInt8] = [0x68, 0xEE, 0x3C, 0x80]
    private static let idr: [UInt8] = [0x65, 0x88, 0x84]

    /// One RTP packet from the phone.
    private static func rtp(sequence: UInt16, marker: Bool = false, _ payload: [UInt8]) -> Data {
        var bytes: [UInt8] = [0x80, (marker ? 0x80 : 0) | 123]
        bytes += withUnsafeBytes(of: sequence.bigEndian, Array.init)
        bytes += withUnsafeBytes(of: UInt32(9000).bigEndian, Array.init)
        bytes += withUnsafeBytes(of: phoneSource.bigEndian, Array.init)
        return Data(bytes + payload)
    }

    /// A keyframe with its parameter sets, as the phone first sends it.
    private static let keyframe = [rtp(sequence: 1, sps), rtp(sequence: 2, pps), rtp(sequence: 3, marker: true, idr)]

    private static func surface() -> IOSurface {
        IOSurface(properties: [.width: 4, .height: 4, .bytesPerElement: 4, .pixelFormat: 0x4247_5241])!
    }

    /// What reached the receiver's callers, recorded.
    private final class Pictures: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var received: Int { lock.withLock { count } }
        func take(_ surface: IOSurface) { lock.withLock { count += 1 } }
    }

    private final class DecoderRig: @unchecked Sendable {
        let decoder = MockStreamDecoder()
        private let lock = NSLock()
        private var _onFrame: (@Sendable (IOSurface) -> Void)?
        var onFrame: (@Sendable (IOSurface) -> Void)? { lock.withLock { _onFrame } }
        init() {
            given(decoder).configure(parameterSets: .any, screen: .any, onFrame: .any).willProduce { [self] _, _, onFrame in
                lock.withLock { _onFrame = onFrame }
            }
            given(decoder).decode(.any).willReturn()
            given(decoder).stop().willReturn()
        }
    }

    /// A receiver that has accepted the phone's answer and started.
    private func started(_ rig: DecoderRig, pictures: Pictures = Pictures()) throws -> RTPReceiver {
        let receiver = RTPReceiver(makeDecoder: { rig.decoder },
                                   mac: { MediaStreamOffer.Mac(model: "Mac16,1", build: "25A1") },
                                   now: { Date(timeIntervalSinceReferenceDate: 0) }, pause: {})
        try receiver.accept(Self.answer)
        try receiver.start(croppedTo: Self.screen) { pictures.take($0) }
        return receiver
    }

    @Test func `should decode the phone's pictures, cropped to its screen, once their parameter sets arrive`() throws {
        let rig = DecoderRig()
        let receiver = try started(rig)

        Self.keyframe.forEach(receiver.receive)

        verify(rig.decoder).configure(parameterSets: .value([Data(Self.sps), Data(Self.pps)]),
                                      screen: .value(Self.screen), onFrame: .any).called(1)
        verify(rig.decoder).decode(.value(AccessUnit(nalUnits: [Data(Self.sps), Data(Self.pps), Data(Self.idr)],
                                                     timestamp: 9000).lengthPrefixedFrame)).called(1)
    }

    @Test func `should pass each decoded picture on`() throws {
        let rig = DecoderRig()
        let pictures = Pictures()
        let receiver = try started(rig, pictures: pictures)
        Self.keyframe.forEach(receiver.receive)

        rig.onFrame?(Self.surface())
        rig.onFrame?(Self.surface())

        #expect(pictures.received == 2)
    }

    @Test func `should ask the phone for a keyframe while it has sent none`() throws {
        let receiver = try started(DecoderRig())

        let reports = (0..<4).compactMap { _ in receiver.nextReport() }

        let loss = RTCPReceiverReport.pictureLossIndication(reporter: Self.ourSource, source: Self.phoneSource)
        #expect(reports.contains(loss))
    }

    @Test func `should pass over the phone's RTCP and anything that isn't RTP`() throws {
        let rig = DecoderRig()
        let receiver = try started(rig)
        let report = Data([0x80, 0xC8, 0x00, 0x06] + [UInt8](repeating: 0, count: 24))

        ([report, Data([1, 2])] + Self.keyframe).forEach(receiver.receive)

        verify(rig.decoder).decode(.any).called(1)
    }

    @Test func `should refuse an answer that doesn't say where the stream comes from`() {
        let receiver = RTPReceiver(makeDecoder: { MockStreamDecoder() }, pause: {})

        #expect(throws: CoreDeviceScreen.StreamError.unexpectedAnswer) { try receiver.accept([:]) }
    }

    @Test func `should stop its decoder when stopped`() throws {
        let rig = DecoderRig()
        let receiver = try started(rig)
        Self.keyframe.forEach(receiver.receive)

        receiver.stop()

        verify(rig.decoder).stop().called(1)
    }
}
