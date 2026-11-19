import BaguetteDevice
import Foundation
import IOSurface

/// A physical phone's live screen through CoreDevice — beside
/// `DevicectlScreen`, its stills through devicectl; the phone registers one
/// of the two, by whether this Mac has CoreDevice. One session from start to
/// stop, each of its rules owned here once:
///
/// 1. reach the phone — its tunnel brought up (`Tunnel`);
/// 2. ask it for its screen — the receiver's offer through CoreDevice's
///    media stream (`MediaStreamStarter`), CoreDevice's answer back to it;
/// 3. carry the datagrams — the phone's into the receiver, the receiver's
///    reports back to where the phone streams from (`DatagramSocket`);
/// 4. hand each picture on as the receiver decodes it, cropped to the
///    phone's screen;
/// 5. end — on `stop`, or when no picture comes within eight seconds —
///    with a goodbye to the phone.
///
/// A start that fails throws, so the failure is seen rather than hidden
/// behind stills. Who turns the stream into pictures is the
/// `ScreenReceiver` (`RTPReceiver` or `AVConferenceReceiver`, as
/// `PhoneScreenRoute` says). Research: docs/features/real-devices/design.md
/// and screen-routes.md.
final class CoreDeviceScreen: Screen, @unchecked Sendable {
    private let identifier: UUID
    private let devicectl: Devicectl
    private let tunnel: any Tunnel
    private let starter: any MediaStreamStarter
    private let openSocket: @Sendable () throws -> any DatagramSocket
    private let makeReceiver: @Sendable () throws -> any ScreenReceiver
    private let now: @Sendable () -> Date
    private let pace: @Sendable () -> Void
    private let lock = NSLock()
    private var running = false
    private var streaming = false
    private var socket: (any DatagramSocket)?
    private var receiver: (any ScreenReceiver)?
    private var session: MediaStreamSession?
    private var packets = 0
    private var pictures = 0
    private var shownAny = false

    init(identifier: UUID,
         devicectl: Devicectl = Devicectl(),
         tunnel: any Tunnel = CoreDeviceTunnel(),
         starter: any MediaStreamStarter = CoreDeviceMediaStream(),
         openSocket: @escaping @Sendable () throws -> any DatagramSocket = { try UDPSocket() },
         makeReceiver: @escaping @Sendable () throws -> any ScreenReceiver = { RTPReceiver() },
         now: @escaping @Sendable () -> Date = { Date() },
         pace: @escaping @Sendable () -> Void = { Thread.sleep(forTimeInterval: 0.05) }) {
        self.identifier = identifier
        self.devicectl = devicectl
        self.tunnel = tunnel
        self.starter = starter
        self.openSocket = openSocket
        self.makeReceiver = makeReceiver
        self.now = now
        self.pace = pace
    }

    /// Starts the session, or throws why it couldn't; pictures then come
    /// to `onFrame` as they are decoded.
    func start(onFrame: @escaping @Sendable (IOSurface) -> Void) throws {
        lock.withLock { running = true }
        do {
            try begin(onFrame)
        } catch {
            endSession()
            throw error
        }
        Thread.detachNewThread { [self] in watch() }
    }

    func stop() {
        lock.withLock { running = false }
        endSession()
    }

    private var isRunning: Bool { lock.withLock { running } }
    private var isStreaming: Bool { lock.withLock { running && streaming } }

    /// Says goodbye to the phone, then stops the receiver and closes the socket.
    private func endSession() {
        let (socket, receiver, session) = lock.withLock {
            streaming = false
            defer { self.socket = nil; self.receiver = nil; self.session = nil }
            return (self.socket, self.receiver, self.session)
        }
        if let socket, let session {
            socket.send(MediaStreamSession.goodbye(from: session.ourSource), to: session.phoneHost, port: session.phonePort)
        }
        receiver?.stop()
        socket?.close()
    }

    // MARK: - The stream

    private func begin(_ onFrame: @escaping @Sendable (IOSurface) -> Void) throws {
        let ends = try tunnel.open(to: identifier)
        let socket = try openSocket()
        let receiver = try makeReceiver()
        lock.withLock {
            self.socket = socket
            self.receiver = receiver
            streaming = true
        }
        let offer = try receiver.offer()
        let (mac, port) = (ends.mac, socket.port)
        let answer = try starter.start(on: identifier) {
            MediaStreamSession.startRequest(offer: offer, receiverIP: mac, port: port)
        }
        guard let session = MediaStreamSession(answer: answer) else { throw StreamError.unexpectedAnswer }
        lock.withLock { self.session = session }
        try receiver.accept(answer)
        // The phone pads its pictures (1328 × 2896 for a 1320 × 2868 screen).
        try receiver.start(croppedTo: devicectl.screenPixels(of: identifier)) { [self] surface in
            guard lock.withLock({ guard running && streaming else { return false }; pictures += 1; shownAny = true; return true })
            else { return }
            onFrame(surface)
        }

        relay(socket: socket, receiver: receiver, session: session)
    }

    /// The phone's datagrams to the receiver, and its reports back to the phone.
    private func relay(socket: any DatagramSocket, receiver: any ScreenReceiver, session: MediaStreamSession) {
        Thread.detachNewThread { [self] in
            while isStreaming {
                guard let datagram = socket.receive() else { continue }
                lock.withLock { packets += 1 }
                receiver.receive(datagram)
            }
        }
        Thread.detachNewThread { [self] in
            while isStreaming {
                guard let report = receiver.nextReport() else { continue }
                socket.send(report, to: session.phoneHost, port: session.phonePort)
            }
        }
    }

    /// While the stream runs: every five seconds, what came is logged; no
    /// picture within the first eight ends the session.
    private func watch() {
        let opened = now()
        var since = opened
        while isStreaming {
            if !lock.withLock({ shownAny }), now().timeIntervalSince(opened) > 8 {
                log("[coredevice] the phone sent no picture within eight seconds; live screen ended")
                endSession()
                return
            }
            if now().timeIntervalSince(since) >= 5 {
                let (packets, pictures) = lock.withLock {
                    defer { self.packets = 0; self.pictures = 0 }
                    return (self.packets, self.pictures)
                }
                log("[coredevice] stream: \(packets) packets, \(pictures) frames")
                since = now()
            }
            pace()
        }
    }

    enum StreamError: Error {
        case notListed, unexpectedAnswer
    }
}
