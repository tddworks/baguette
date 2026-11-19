import BaguetteDevice
import Foundation
import IOSurface

/// A physical phone's live screen received by AVConference itself, in this
/// process — the route `BAGUETTE_PHONE_SCREEN=avconference` picks (see
/// `PhoneScreenRoute`), beside baguette's own `MediaStreamScreen`.
///
/// The phone's stream is started through CoreDevice with AVConference's
/// own offer; AVConference takes the answer, receives, paces and decodes
/// (HEVC). This screen carries the datagrams between the tunnel and the
/// mirroring, and hands each picture on as the mirroring decodes it — a
/// push, so pictures keep AVConference's own pacing. CoreDevice, the
/// socket and AVConference are roles (`MediaStreamStarter`,
/// `DatagramSocket`, `Mirroring`). When the stream can't start, or shows
/// nothing within eight seconds, the screen falls back to `fallback`
/// (screenshots). Research: docs/features/real-devices/design.md.
final class AVConferenceScreen: Screen, @unchecked Sendable {
    private let identifier: UUID
    private let devicectl: Devicectl
    private let fallback: any Screen
    private let tunnel: any Tunnel
    private let starter: any MediaStreamStarter
    private let openSocket: @Sendable () throws -> any DatagramSocket
    private let makeMirroring: @Sendable () throws -> any Mirroring
    private let now: @Sendable () -> Date
    private let pace: @Sendable () -> Void
    private let lock = NSLock()
    private var running = false
    private var streaming = false
    private var socket: (any DatagramSocket)?
    private var mirroring: (any Mirroring)?
    private var session: MediaStreamSession?
    private var usingFallback = false
    private var packets = 0
    private var pictures = 0
    private var shownAny = false

    init(identifier: UUID,
         devicectl: Devicectl = Devicectl(),
         fallback: any Screen,
         tunnel: any Tunnel = CoreDeviceTunnel(),
         starter: any MediaStreamStarter = CoreDeviceMediaStream(),
         openSocket: @escaping @Sendable () throws -> any DatagramSocket = { try UDPSocket() },
         makeMirroring: @escaping @Sendable () throws -> any Mirroring = { try AVConferenceMirroring() },
         now: @escaping @Sendable () -> Date = { Date() },
         pace: @escaping @Sendable () -> Void = { Thread.sleep(forTimeInterval: 0.05) }) {
        self.identifier = identifier
        self.devicectl = devicectl
        self.fallback = fallback
        self.tunnel = tunnel
        self.starter = starter
        self.openSocket = openSocket
        self.makeMirroring = makeMirroring
        self.now = now
        self.pace = pace
    }

    func start(onFrame: @escaping @Sendable (IOSurface) -> Void) throws {
        lock.withLock { running = true }
        Thread.detachNewThread { [self] in
            do {
                try stream(onFrame)
            } catch {
                endSession()
                guard isRunning else { return }
                log("[coredevice] live screen (avconference) unavailable (\(error)); showing screenshots")
                lock.withLock { usingFallback = true }
                try? fallback.start(onFrame: onFrame)
            }
        }
    }

    func stop() {
        let fellBack = lock.withLock {
            running = false
            return usingFallback
        }
        endSession()
        if fellBack { fallback.stop() }
    }

    private var isRunning: Bool { lock.withLock { running } }
    private var isStreaming: Bool { lock.withLock { running && streaming } }

    /// Says goodbye to the phone, then stops the mirroring and closes the socket.
    private func endSession() {
        let (socket, mirroring, session) = lock.withLock {
            streaming = false
            defer { self.socket = nil; self.mirroring = nil; self.session = nil }
            return (self.socket, self.mirroring, self.session)
        }
        if let socket, let session {
            socket.send(MediaStreamSession.goodbye(from: session.ourSource), to: session.phoneHost, port: session.phonePort)
        }
        mirroring?.stop()
        socket?.close()
    }

    // MARK: - The stream

    private func stream(_ onFrame: @escaping @Sendable (IOSurface) -> Void) throws {
        let ends = try tunnel.open(to: identifier)
        let socket = try openSocket()
        let mirroring = try makeMirroring()
        lock.withLock {
            self.socket = socket
            self.mirroring = mirroring
            streaming = true
        }
        let offer = try mirroring.offer()
        let (mac, port) = (ends.mac, socket.port)
        let answer = try starter.start(on: identifier) {
            MediaStreamSession.startRequest(offer: offer, receiverIP: mac, port: port)
        }
        guard let session = MediaStreamSession(answer: answer),
              let negotiated = MediaStreamSession.negotiatorAnswer(in: answer)
        else { throw MediaStreamScreen.StreamError.unexpectedAnswer }
        lock.withLock { self.session = session }
        try mirroring.accept(answer: negotiated)
        // The phone pads its pictures (1328 × 2896 for a 1320 × 2868 screen).
        try mirroring.start(croppedTo: devicectl.screenPixels(of: identifier)) { [self] surface in
            guard lock.withLock({ guard running && streaming else { return false }; pictures += 1; shownAny = true; return true })
            else { return }
            onFrame(surface)
        }

        relay(socket: socket, mirroring: mirroring, session: session)
        try watch()
    }

    /// The phone's datagrams to the mirroring, and its reports back to the phone.
    private func relay(socket: any DatagramSocket, mirroring: any Mirroring, session: MediaStreamSession) {
        Thread.detachNewThread { [self] in
            while isStreaming {
                guard let datagram = socket.receive() else { continue }
                lock.withLock { packets += 1 }
                mirroring.deliver(datagram)
            }
        }
        Thread.detachNewThread { [self] in
            while isStreaming {
                guard let report = mirroring.nextReport() else { continue }
                socket.send(report, to: session.phoneHost, port: session.phonePort)
            }
        }
    }

    /// While the stream runs: none of its pictures within eight seconds
    /// gives up for the screenshots; every five, what came is logged.
    private func watch() throws {
        let opened = now()
        var since = opened
        while isStreaming {
            if !lock.withLock({ shownAny }), now().timeIntervalSince(opened) > 8 {
                throw MediaStreamScreen.StreamError.silent
            }
            if now().timeIntervalSince(since) >= 5 {
                let (packets, pictures) = lock.withLock {
                    defer { self.packets = 0; self.pictures = 0 }
                    return (self.packets, self.pictures)
                }
                log("[coredevice] stream (avconference): \(packets) packets, \(pictures) frames")
                since = now()
            }
            pace()
        }
    }
}
