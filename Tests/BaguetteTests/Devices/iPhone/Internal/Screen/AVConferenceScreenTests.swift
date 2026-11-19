import Foundation
import IOSurface
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// A phone's live screen through AVConference's own receiver, with the
/// tunnel, CoreDevice, the socket, the mirroring and the screenshots stood
/// in for: what the phone is asked, which datagrams go where, which pictures
/// go on, and when it falls back to screenshots.
@Suite("AVConferenceScreen")
struct AVConferenceScreenTests {
    private static let offer = Data([0x62, 0x70, 0x6C, 0x69])
    private static let negotiated = Data([7, 7, 7])
    nonisolated(unsafe) private static let answer: [String: Any] = [
        "negotiatorAnswer": negotiated.base64EncodedString(),
        "connection": ["streamConfig": [
            "SourceIP": PhoneJSON.tunnel, "SourcePort": NSNumber(value: 61000),
            "LocalSSRC": NSNumber(value: 0xE95D_3647), "RemoteSSRC": NSNumber(value: 7),
        ]],
    ]

    private static func surface() -> IOSurface {
        IOSurface(properties: [.width: 4, .height: 4, .bytesPerElement: 4, .pixelFormat: 0x4247_5241])!
    }

    /// Signals once something has happened, for a test to wait on.
    private final class Signal: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        func fire() { semaphore.signal() }
        func wait() -> Bool { semaphore.wait(timeout: .now() + 5) == .success }
    }

    /// A clock that moves on `step` seconds each time it is read.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var now = Date(timeIntervalSinceReferenceDate: 0)
        let step: TimeInterval
        init(step: TimeInterval) { self.step = step }
        func read() -> Date { lock.withLock { defer { now += step }; return now } }
    }

    /// Everything the screen talks to, recorded.
    private final class Rig: @unchecked Sendable {
        let tunnel = MockTunnel()
        let starter = MockMediaStreamStarter()
        let socket = MockDatagramSocket()
        let mirroring = MockMirroring()
        let fallback = MockScreen()
        let fellBack = Signal()
        let delivered = Signal()
        let reported = Signal()
        let pictured = Signal()
        let stopped = Signal()
        private let lock = NSLock()
        private var inbound: [Data]
        private var reports: [Data]
        private var pictures: [MirroredPicture?]
        private var _request: [String: Any]?
        private var _steps: [String] = []
        private var _frames = 0

        var request: [String: Any]? { lock.withLock { _request } }
        var steps: [String] { lock.withLock { _steps } }
        var frames: Int { lock.withLock { _frames } }

        init(inbound: [Data] = [], reports: [Data] = [], pictures: [MirroredPicture?] = [],
             answer: [String: Any] = AVConferenceScreenTests.answer, mirroringStarts: Bool = true) {
            self.inbound = inbound
            self.reports = reports
            self.pictures = pictures
            given(tunnel).open(to: .any).willReturn(TunnelEnds(phone: PhoneJSON.tunnel, mac: PhoneJSON.mac))
            given(starter).start(on: .any, request: .any).willProduce { [self] _, makeRequest in
                let request = try makeRequest()
                lock.withLock { _request = request; _steps.append("start stream") }
                return answer
            }
            given(socket).port.willReturn(50001)
            given(socket).receive().willProduce { [self] in
                let next = lock.withLock { self.inbound.isEmpty ? nil : self.inbound.removeFirst() }
                if next == nil { Thread.sleep(forTimeInterval: 0.002) }
                return next
            }
            given(socket).send(.any, to: .any, port: .any).willProduce { [self] _, _, _ in reported.fire() }
            given(socket).close().willReturn()
            given(mirroring).offer().willReturn(AVConferenceScreenTests.offer)
            given(mirroring).accept(answer: .any).willProduce { [self] _ in lock.withLock { _steps.append("accept") } }
            given(mirroring).start().willProduce { [self] in
                lock.withLock { _steps.append("start mirroring") }
                guard mirroringStarts else { throw TunnelError.down }
            }
            given(mirroring).deliver(.any).willProduce { [self] _ in delivered.fire() }
            given(mirroring).nextReport().willProduce { [self] in
                let next = lock.withLock { self.reports.isEmpty ? nil : self.reports.removeFirst() }
                if next == nil { Thread.sleep(forTimeInterval: 0.002) }
                return next
            }
            given(mirroring).latestPicture().willProduce { [self] in
                lock.withLock { self.pictures.count > 1 ? self.pictures.removeFirst() : self.pictures.first ?? nil }
            }
            given(mirroring).stop().willProduce { [self] in stopped.fire() }
            given(fallback).start(onFrame: .any).willProduce { [self] _ in fellBack.fire() }
            given(fallback).stop().willReturn()
        }

        func screen(clock: Clock = Clock(step: 0.001)) -> AVConferenceScreen {
            let (socket, mirroring) = (socket, mirroring)
            return AVConferenceScreen(
                identifier: PhoneJSON.identifier, fallback: fallback, tunnel: tunnel, starter: starter,
                openSocket: { socket }, makeMirroring: { mirroring }, now: clock.read, pace: {})
        }

        func onFrame(_ surface: IOSurface) {
            lock.withLock { _frames += 1 }
            pictured.fire()
        }
    }

    @Test func `should start the phone's stream with the mirroring's offer, sent to this Mac's end of its tunnel`() throws {
        let rig = Rig(pictures: [MirroredPicture(surface: Self.surface(), sequence: 1)])
        let screen = rig.screen()

        try screen.start { rig.onFrame($0) }
        #expect(rig.pictured.wait())
        screen.stop()

        #expect(rig.request?["negotiatorOffer"] as? String == Self.offer.base64EncodedString())
        #expect(rig.request?["receiverIP"] as? String == PhoneJSON.mac)
        #expect(rig.request?["receiverPort"] as? Int == 50001)
        verify(rig.tunnel).open(to: .value(PhoneJSON.identifier)).called(1)
    }

    @Test func `should hand the phone's answer to the mirroring before it starts`() throws {
        let rig = Rig(pictures: [MirroredPicture(surface: Self.surface(), sequence: 1)])
        let screen = rig.screen()

        try screen.start { rig.onFrame($0) }
        #expect(rig.pictured.wait())
        screen.stop()

        verify(rig.mirroring).accept(answer: .value(Self.negotiated)).called(1)
        #expect(rig.steps == ["start stream", "accept", "start mirroring"])
    }

    @Test func `should pass the phone's datagrams on to the mirroring`() throws {
        let datagram = Data([0x80, 0x64, 0, 1])
        let rig = Rig(inbound: [datagram])
        let screen = rig.screen()

        try screen.start { rig.onFrame($0) }
        #expect(rig.delivered.wait())
        screen.stop()

        verify(rig.mirroring).deliver(.value(datagram)).called(1)
    }

    @Test func `should send the mirroring's reports to where the phone streams from`() throws {
        let report = Data([0x81, 0xC9, 0, 1])
        let rig = Rig(reports: [report])
        let screen = rig.screen()

        try screen.start { rig.onFrame($0) }
        #expect(rig.reported.wait())
        screen.stop()

        verify(rig.socket).send(.value(report), to: .value(PhoneJSON.tunnel), port: .value(61000)).called(1)
    }

    @Test func `should pass each new picture on once`() throws {
        let surface = Self.surface()
        let rig = Rig(pictures: [MirroredPicture(surface: surface, sequence: 1), MirroredPicture(surface: surface, sequence: 1),
                                 MirroredPicture(surface: surface, sequence: 2)])
        let screen = rig.screen()

        try screen.start { rig.onFrame($0) }
        #expect(rig.pictured.wait())
        #expect(rig.pictured.wait())
        Thread.sleep(forTimeInterval: 0.05)
        screen.stop()

        #expect(rig.frames == 2)
    }

    @Test func `should stop the mirroring and close its socket when stopped`() throws {
        let rig = Rig(pictures: [MirroredPicture(surface: Self.surface(), sequence: 1)])
        let screen = rig.screen()

        try screen.start { rig.onFrame($0) }
        #expect(rig.pictured.wait())
        screen.stop()

        #expect(rig.stopped.wait())
        verify(rig.socket).close().called(.moreOrEqual(to: 1))
        verify(rig.fallback).stop().called(0)
    }

    @Test func `should show screenshots when the mirroring can't start`() throws {
        let rig = Rig(mirroringStarts: false)
        let screen = rig.screen()

        try screen.start { rig.onFrame($0) }

        #expect(rig.fellBack.wait())
        screen.stop()
        verify(rig.fallback).stop().called(1)
    }

    @Test func `should show screenshots when CoreDevice's answer carries no negotiator's answer`() throws {
        var answer = Self.answer
        answer["negotiatorAnswer"] = nil
        let rig = Rig(answer: answer)
        let screen = rig.screen()

        try screen.start { rig.onFrame($0) }

        #expect(rig.fellBack.wait())
        screen.stop()
        verify(rig.mirroring).start().called(0)
    }

    @Test func `should show screenshots when no picture arrives within eight seconds`() throws {
        let rig = Rig()
        let screen = rig.screen(clock: Clock(step: 1))

        try screen.start { rig.onFrame($0) }

        #expect(rig.fellBack.wait())
        screen.stop()
        #expect(rig.frames == 0)
    }
}
