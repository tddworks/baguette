import Foundation
import IOSurface
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// A phone's live screen through CoreDevice, whichever receiver turns its
/// stream into pictures: with the tunnel, CoreDevice, the socket and the
/// receiver stood in for — what the phone is asked, which datagrams go where,
/// which pictures go on, and when it refuses to start or ends.
@Suite("CoreDeviceScreen")
struct CoreDeviceScreenTests {
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

    /// Everything the screen talks to, recorded. A test with no picture
    /// meets the eight-second silence rule within a few thousand reads of
    /// the fast clock, so each test not about silence gets one.
    private final class Rig: @unchecked Sendable {
        let tunnel = MockTunnel()
        let starter = MockMediaStreamStarter()
        let socket = MockDatagramSocket()
        let receiver = MockScreenReceiver()
        let devicectl = PhoneJSON.devicectl(listings: [PhoneJSON.listing(tunnelAddress: PhoneJSON.tunnel)])
        let delivered = Signal()
        let reported = Signal()
        let pictured = Signal()
        let stopped = Signal()
        private let lock = NSLock()
        private var inbound: [Data]
        private var reports: [Data]
        private let pictures: Int
        private var _onPicture: (@Sendable (IOSurface) -> Void)?
        /// What the receiver was told to call with each decoded picture.
        var onPicture: (@Sendable (IOSurface) -> Void)? { lock.withLock { _onPicture } }
        private var _request: [String: Any]?
        private var _steps: [String] = []
        private var _accepted: String?
        /// The part of CoreDevice's answer the receiver was handed, by its negotiator's answer.
        var accepted: String? { lock.withLock { _accepted } }
        private var _frames = 0

        var request: [String: Any]? { lock.withLock { _request } }
        var steps: [String] { lock.withLock { _steps } }
        var frames: Int { lock.withLock { _frames } }

        init(inbound: [Data] = [], reports: [Data] = [], pictures: Int = 0,
             answer: [String: Any] = CoreDeviceScreenTests.answer, receiverStarts: Bool = true) {
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
            given(receiver).offer().willReturn(CoreDeviceScreenTests.offer)
            given(receiver).accept(.any).willProduce { [self] answer in
                lock.withLock { _steps.append("accept"); _accepted = answer["negotiatorAnswer"] as? String }
            }
            given(receiver).start(croppedTo: .any, onPicture: .any).willProduce { [self] _, onPicture in
                lock.withLock { _steps.append("start receiving"); _onPicture = onPicture }
                guard receiverStarts else { throw TunnelError.down }
                for _ in 0..<pictures { onPicture(CoreDeviceScreenTests.surface()) }
            }
            given(receiver).receive(.any).willProduce { [self] _ in delivered.fire() }
            given(receiver).nextReport().willProduce { [self] in
                let next = lock.withLock { self.reports.isEmpty ? nil : self.reports.removeFirst() }
                if next == nil { Thread.sleep(forTimeInterval: 0.002) }
                return next
            }
            given(receiver).stop().willProduce { [self] in stopped.fire() }
        }

        func screen(clock: Clock = Clock(step: 0.001)) -> CoreDeviceScreen {
            let (socket, receiver) = (socket, receiver)
            return CoreDeviceScreen(
                identifier: PhoneJSON.identifier, devicectl: Devicectl(makeSubprocess: devicectl.make),
                tunnel: tunnel, starter: starter,
                openSocket: { socket }, makeReceiver: { receiver }, now: clock.read, pace: {})
        }

        func onFrame(_ surface: IOSurface) {
            lock.withLock { _frames += 1 }
            pictured.fire()
        }
    }

    @Test func `should start the phone's stream with the receiver's offer, sent to this Mac's end of its tunnel`() throws {
        let rig = Rig(pictures: 1)
        let screen = rig.screen()

        try screen.start { rig.onFrame($0) }
        #expect(rig.pictured.wait())
        screen.stop()

        #expect(rig.request?["negotiatorOffer"] as? String == Self.offer.base64EncodedString())
        #expect(rig.request?["receiverIP"] as? String == PhoneJSON.mac)
        #expect(rig.request?["receiverPort"] as? Int == 50001)
        verify(rig.tunnel).open(to: .value(PhoneJSON.identifier)).called(1)
    }

    @Test func `should hand CoreDevice's answer to the receiver before it starts`() throws {
        let rig = Rig(pictures: 1)
        let screen = rig.screen()

        try screen.start { rig.onFrame($0) }
        #expect(rig.pictured.wait())
        screen.stop()

        #expect(rig.accepted == Self.negotiated.base64EncodedString())
        #expect(rig.steps == ["start stream", "accept", "start receiving"])
    }

    @Test func `should crop the phone's pictures to its screen`() throws {
        let rig = Rig(pictures: 1)
        let screen = rig.screen()

        try screen.start { rig.onFrame($0) }
        #expect(rig.pictured.wait())
        screen.stop()

        verify(rig.receiver).start(croppedTo: .value(Size(width: 1320, height: 2868)), onPicture: .any).called(1)
    }

    @Test func `should pass the phone's datagrams on to the receiver`() throws {
        let datagram = Data([0x80, 0x64, 0, 1])
        let rig = Rig(inbound: [datagram], pictures: 1)
        let screen = rig.screen()

        try screen.start { rig.onFrame($0) }
        #expect(rig.delivered.wait())
        screen.stop()

        verify(rig.receiver).receive(.value(datagram)).called(1)
    }

    @Test func `should send the receiver's reports to where the phone streams from`() throws {
        let report = Data([0x81, 0xC9, 0, 1])
        let rig = Rig(reports: [report], pictures: 1)
        let screen = rig.screen()

        try screen.start { rig.onFrame($0) }
        #expect(rig.reported.wait())
        screen.stop()

        verify(rig.socket).send(.value(report), to: .value(PhoneJSON.tunnel), port: .value(61000)).called(1)
    }

    @Test func `should pass on each picture as the receiver decodes it`() throws {
        let rig = Rig(pictures: 2)
        let screen = rig.screen()

        try screen.start { rig.onFrame($0) }
        #expect(rig.pictured.wait())
        #expect(rig.pictured.wait())
        screen.stop()

        #expect(rig.frames == 2)
    }

    @Test func `should pass on no picture once the screen stops`() throws {
        let rig = Rig(pictures: 1)
        let screen = rig.screen()

        try screen.start { rig.onFrame($0) }
        #expect(rig.pictured.wait())
        screen.stop()
        rig.onPicture?(Self.surface())

        #expect(rig.frames == 1)
    }

    @Test func `should stop the receiver and close its socket when stopped`() throws {
        let rig = Rig(pictures: 1)
        let screen = rig.screen()

        try screen.start { rig.onFrame($0) }
        #expect(rig.pictured.wait())
        screen.stop()

        #expect(rig.stopped.wait())
        verify(rig.socket).close().called(.moreOrEqual(to: 1))
    }

    @Test func `should refuse to start when the receiver can't start`() throws {
        let rig = Rig(receiverStarts: false)
        let screen = rig.screen()

        #expect(throws: TunnelError.down) { try screen.start { rig.onFrame($0) } }

        verify(rig.socket).close().called(.moreOrEqual(to: 1))
    }

    @Test func `should refuse to start when CoreDevice's answer doesn't say where the stream comes from`() throws {
        let rig = Rig(answer: ["negotiatorAnswer": Self.negotiated.base64EncodedString()])
        let screen = rig.screen()

        #expect(throws: CoreDeviceScreen.StreamError.unexpectedAnswer) { try screen.start { rig.onFrame($0) } }

        verify(rig.receiver).start(croppedTo: .any, onPicture: .any).called(0)
    }

    @Test func `should end the session when no picture arrives within eight seconds`() throws {
        let rig = Rig()
        let screen = rig.screen(clock: Clock(step: 1))

        try screen.start { rig.onFrame($0) }

        #expect(rig.stopped.wait())
        verify(rig.socket).close().called(.moreOrEqual(to: 1))
        #expect(rig.frames == 0)
    }
}
