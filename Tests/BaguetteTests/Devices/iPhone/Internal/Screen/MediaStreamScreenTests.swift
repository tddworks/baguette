import Foundation
import IOSurface
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// A phone's live screen with CoreDevice, the socket, the decoder and
/// devicectl stood in for: what is asked of the phone, which of its
/// packets become pictures, and when it falls back to screenshots.
@Suite("MediaStreamScreen")
struct MediaStreamScreenTests {
    private static let phoneSource: UInt32 = 0xE95D_3647
    private static let ourSource: UInt32 = 7
    nonisolated(unsafe) private static let answer: [String: Any] = ["connection": ["streamConfig": [
        "SourceIP": PhoneJSON.tunnel, "SourcePort": NSNumber(value: 61000),
        "LocalSSRC": NSNumber(value: phoneSource), "RemoteSSRC": NSNumber(value: ourSource),
    ]]]

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

    /// Signals once something has happened, for a test to wait on.
    private final class Signal: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        func fire() { semaphore.signal() }
        func wait() -> Bool { semaphore.wait(timeout: .now() + 5) == .success }
    }

    /// A clock that moves on a second each time it is read.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var now = Date(timeIntervalSinceReferenceDate: 0)
        let step: TimeInterval
        init(step: TimeInterval) { self.step = step }
        func read() -> Date { lock.withLock { defer { now += step }; return now } }
    }

    /// Everything the screen talks to, recorded.
    private final class Rig: @unchecked Sendable {
        let socket = MockDatagramSocket()
        let starter = MockMediaStreamStarter()
        let decoder = MockStreamDecoder()
        let fallback = MockScreen()
        let devicectl = PhoneJSON.devicectl(listings: [PhoneJSON.listing(tunnelAddress: PhoneJSON.tunnel)])
        let fellBack = Signal()
        let decoded = Signal()
        let closed = Signal()
        private let lock = NSLock()
        private var inbound: [Data]
        private var _sent: [(Data, String, UInt16)] = []
        private var _request: [String: Any]?
        private var _cropped: Size?

        var sent: [(Data, String, UInt16)] { lock.withLock { _sent } }
        var request: [String: Any]? { lock.withLock { _request } }
        var cropped: Size? { lock.withLock { _cropped } }

        init(inbound: [Data] = [], answer: [String: Any]? = MediaStreamScreenTests.answer) {
            self.inbound = inbound
            given(socket).port.willReturn(50001)
            given(socket).receive().willProduce { [self] in
                let next = lock.withLock { self.inbound.isEmpty ? nil : self.inbound.removeFirst() }
                if next == nil { Thread.sleep(forTimeInterval: 0.002) }
                return next
            }
            given(socket).send(.any, to: .any, port: .any).willProduce { [self] data, host, port in
                lock.withLock { _sent.append((data, host, port)) }
            }
            given(socket).close().willProduce { [self] in closed.fire() }
            given(starter).start(on: .any, request: .any).willProduce { [self] _, makeRequest in
                let request = try makeRequest()
                lock.withLock { _request = request }
                guard let answer else { throw MediaStreamScreen.StreamError.notListed }
                return answer
            }
            given(decoder).configure(parameterSets: .any, screen: .any, onFrame: .any).willProduce { [self] _, screen, _ in
                lock.withLock { _cropped = screen }
            }
            given(decoder).decode(.any).willProduce { [self] _ in decoded.fire() }
            given(decoder).stop().willReturn()
            given(fallback).start(onFrame: .any).willProduce { [self] _ in fellBack.fire() }
            given(fallback).stop().willReturn()
        }

        func screen(
            interfaces: [String] = [PhoneJSON.mac, "::1"],
            openSocket: (@Sendable () throws -> any DatagramSocket)? = nil,
            clock: Clock = Clock(step: 0.001)
        ) -> MediaStreamScreen {
            let socket = socket
            return MediaStreamScreen(
                identifier: PhoneJSON.identifier, devicectl: Devicectl(makeSubprocess: devicectl.make),
                makeDecoder: { [decoder] in decoder }, fallback: fallback, starter: starter,
                openSocket: openSocket ?? { socket },
                mac: { MediaStreamOffer.Mac(model: "Mac16,1", build: "25A1") },
                interfaces: { interfaces }, now: clock.read)
        }
    }

    @Test func `should decode the phone's pictures, cropped to its screen, once their parameter sets arrive`() throws {
        let rig = Rig(inbound: Self.keyframe)
        let screen = rig.screen()

        try screen.start { _ in }
        #expect(rig.decoded.wait())
        screen.stop()

        verify(rig.decoder).configure(parameterSets: .value([Data(Self.sps), Data(Self.pps)]), screen: .any, onFrame: .any)
            .called(1)
        verify(rig.decoder).decode(.value(AccessUnit(nalUnits: [Data(Self.sps), Data(Self.pps), Data(Self.idr)],
                                                     timestamp: 9000).lengthPrefixedFrame)).called(1)
        #expect(rig.cropped == Size(width: 1320, height: 2868))
        verify(rig.fallback).start(onFrame: .any).called(0)
    }

    @Test func `should ask the phone to stream to this Mac's end of its tunnel`() throws {
        let rig = Rig(inbound: Self.keyframe)
        let screen = rig.screen()

        try screen.start { _ in }
        #expect(rig.decoded.wait())
        screen.stop()

        #expect(rig.request?["receiverIP"] as? String == PhoneJSON.mac)
        #expect(rig.request?["receiverPort"] as? Int == 50001)
        verify(rig.starter).start(on: .value(PhoneJSON.identifier), request: .any).called(1)
    }

    @Test func `should ask the phone for a keyframe where it streams from while it has sent none`() throws {
        let rig = Rig(inbound: Self.keyframe)
        let screen = rig.screen()

        try screen.start { _ in }
        #expect(rig.decoded.wait())
        screen.stop()

        let loss = RTCPReceiverReport.pictureLossIndication(reporter: Self.ourSource, source: Self.phoneSource)
        #expect(rig.sent.contains { $0.0 == loss && $0.1 == PhoneJSON.tunnel && $0.2 == 61000 })
    }

    @Test func `should say goodbye to the phone and close its socket when stopped`() throws {
        let rig = Rig(inbound: Self.keyframe)
        let screen = rig.screen()

        try screen.start { _ in }
        #expect(rig.decoded.wait())
        screen.stop()

        let goodbye = MediaStreamSession.goodbye(from: Self.ourSource)
        #expect(rig.sent.contains { $0.0 == goodbye && $0.1 == PhoneJSON.tunnel && $0.2 == 61000 })
        verify(rig.socket).close().called(1)
        verify(rig.decoder).stop().called(1)
        verify(rig.fallback).stop().called(0)
    }

    @Test func `should show screenshots when CoreDevice can't start the stream`() throws {
        let rig = Rig(answer: nil)
        let screen = rig.screen()

        try screen.start { _ in }

        #expect(rig.fellBack.wait())
        screen.stop()
        verify(rig.fallback).stop().called(1)
    }

    @Test func `should show screenshots when CoreDevice's answer doesn't say where the stream comes from`() throws {
        let rig = Rig(answer: [:])
        let screen = rig.screen()

        try screen.start { _ in }

        #expect(rig.fellBack.wait())
        screen.stop()
    }

    @Test func `should show screenshots when this Mac has no address on the phone's tunnel`() throws {
        let rig = Rig()
        let screen = rig.screen(interfaces: ["::1"])

        try screen.start { _ in }

        #expect(rig.fellBack.wait())
        screen.stop()
        #expect(rig.request == nil)
    }

    @Test func `should show screenshots when no socket can be opened for the stream`() throws {
        struct NoSocket: Error {}
        let rig = Rig()
        let screen = rig.screen(openSocket: { throw NoSocket() })

        try screen.start { _ in }

        #expect(rig.fellBack.wait())
        screen.stop()
        verify(rig.starter).start(on: .any, request: .any).called(0)
    }

    @Test func `should show screenshots when no picture arrives within eight seconds`() throws {
        let rig = Rig(inbound: [Self.rtp(sequence: 1, Self.sps)])
        let screen = rig.screen(clock: Clock(step: 1))

        try screen.start { _ in }

        #expect(rig.fellBack.wait())
        screen.stop()
        verify(rig.decoder).decode(.any).called(0)
    }

    @Test func `should pass over the phone's RTCP and anything that isn't RTP`() throws {
        let report = Data([0x80, 0xC8, 0x00, 0x06] + [UInt8](repeating: 0, count: 24))
        let rig = Rig(inbound: [report, Data([1, 2])] + Self.keyframe)
        let screen = rig.screen()

        try screen.start { _ in }
        #expect(rig.decoded.wait())
        screen.stop()

        verify(rig.decoder).decode(.any).called(1)
    }
}
