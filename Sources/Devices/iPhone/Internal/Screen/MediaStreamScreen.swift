import BaguetteDevice
import Foundation
import IOSurface

/// A physical phone's live screen: the H.264 stream the phone itself
/// encodes, started through CoreDevice with our own offer
/// (`MediaStreamOffer`) and received here as RTP over the CoreDevice
/// tunnel, without AVConference's receiver (which only Apple's apps may
/// use). About 60 fps.
///
/// The packets, frames and RTCP are pure values (`MediaStreamPackets.swift`,
/// `MediaStreamSession`), decoding is `H264Decoder`'s, and CoreDevice and
/// the socket are roles (`MediaStreamStarter`, `DatagramSocket`). When the
/// stream can't start, the screen falls back to `fallback` (screenshots).
final class MediaStreamScreen: Screen, @unchecked Sendable {
    private let identifier: UUID
    private let devicectl: Devicectl
    private let makeDecoder: @Sendable () -> any StreamDecoder
    private let fallback: any Screen
    private let starter: any MediaStreamStarter
    private let openSocket: @Sendable () throws -> any DatagramSocket
    private let mac: @Sendable () -> MediaStreamOffer.Mac
    private let interfaces: @Sendable () -> [String]
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var running = false
    private var socket: (any DatagramSocket)?
    private var session: MediaStreamSession?
    private var decoder: (any StreamDecoder)?
    private var usingFallback = false

    init(identifier: UUID,
         devicectl: Devicectl = Devicectl(),
         makeDecoder: @escaping @Sendable () -> any StreamDecoder = { VTStreamDecoder() },
         fallback: any Screen,
         starter: any MediaStreamStarter = CoreDeviceMediaStream(),
         openSocket: @escaping @Sendable () throws -> any DatagramSocket = { try UDPSocket() },
         mac: @escaping @Sendable () -> MediaStreamOffer.Mac = { HostNetwork.mac },
         interfaces: @escaping @Sendable () -> [String] = { HostNetwork.addresses() },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.identifier = identifier
        self.devicectl = devicectl
        self.makeDecoder = makeDecoder
        self.fallback = fallback
        self.starter = starter
        self.openSocket = openSocket
        self.mac = mac
        self.interfaces = interfaces
        self.now = now
    }

    func start(onFrame: @escaping @Sendable (IOSurface) -> Void) throws {
        lock.withLock { running = true }
        Thread.detachNewThread { [self] in
            do {
                try stream(onFrame)
            } catch {
                guard isRunning else { return }
                log("[coredevice] live screen unavailable (\(error)); showing screenshots")
                lock.withLock { usingFallback = true }
                try? fallback.start(onFrame: onFrame)
            }
        }
    }

    func stop() {
        let (socket, session, decoder, fellBack) = lock.withLock {
            running = false
            defer { self.socket = nil; self.decoder = nil }
            return (self.socket, self.session, self.decoder, usingFallback)
        }
        if let socket {
            if let session {
                socket.send(MediaStreamSession.goodbye(from: session.ourSource), to: session.phoneHost, port: session.phonePort)
            }
            socket.close()
        }
        decoder?.stop()
        if fellBack { fallback.stop() }
    }

    private var isRunning: Bool { lock.withLock { running } }

    // MARK: - The stream

    private func stream(_ onFrame: @escaping @Sendable (IOSurface) -> Void) throws {
        let socket = try openSocket()
        lock.withLock { self.socket = socket }
        let port = socket.port
        let offer = MediaStreamOffer(
            receiver: UInt32.random(in: 1 ... .max), host: mac(), made: MediaStreamSession.ntpTime(now())).bytes

        let (identifier, devicectl, interfaces) = (self.identifier, self.devicectl, self.interfaces)
        // Asked while the stream starts: the size its pictures are cropped to.
        let screenSize = Answer<Size>()
        Thread.detachNewThread { screenSize.give(Self.screenPixels(identifier, devicectl: devicectl)) }
        let answer = try starter.start(on: identifier) {
            guard let local = Self.localTunnelAddress(identifier, devicectl: devicectl, among: interfaces()) else {
                throw StreamError.noTunnel
            }
            return MediaStreamSession.startRequest(offer: offer, receiverIP: local, port: port)
        }
        guard let session = MediaStreamSession(answer: answer) else { throw StreamError.unexpectedAnswer }
        lock.withLock { self.session = session }

        try receive(on: socket, session: session, screen: { screenSize.wait(upTo: 3) }, onFrame)
    }

    private func receive(on socket: any DatagramSocket, session: MediaStreamSession,
                         screen: () -> Size?, _ onFrame: @escaping @Sendable (IOSurface) -> Void) throws {
        let send = { (report: Data) in socket.send(report, to: session.phoneHost, port: session.phonePort) }
        var depacketizer = VideoDepacketizer()
        var feedback = ReceiverFeedback(reporter: session.ourSource, source: session.phoneSource)
        var gate = DecodeGate()
        var parameterSets: [Data] = []
        var firstFrame: Date?
        var stats = (packets: 0, frames: 0, since: now())
        let opened = now()
        while isRunning {
            // No picture yet — whether nothing arrives or fragments never make
            // a whole frame — gives up for the screenshots instead.
            if firstFrame == nil, now().timeIntervalSince(opened) > 8 { throw StreamError.silent }
            for report in feedback.due(at: now().timeIntervalSince(opened), wantingKeyframe: gate.needsKeyframe) {
                send(report)
            }
            if now().timeIntervalSince(stats.since) >= 5 {
                log("[coredevice] stream: \(stats.packets) packets, \(stats.frames) frames, "
                    + "\(depacketizer.droppedFrames) dropped in all")
                stats = (0, 0, now())
            }
            guard let data = socket.receive(), !RTPPacket.isRTCP(data), let packet = RTPPacket(data) else { continue }
            stats.packets += 1
            for report in feedback.heard(packet) { send(report) }
            guard let unit = depacketizer.push(packet) else { continue }
            let fresh = unit.parameterSets
            if !fresh.isEmpty, fresh != parameterSets {
                let decoder = lock.withLock { self.decoder } ?? makeDecoder()
                try decoder.configure(parameterSets: fresh, screen: screen(), onFrame: onFrame)
                lock.withLock { self.decoder = decoder }
                parameterSets = fresh
            }
            guard gate.admits(unit, droppedSince: depacketizer.droppedFrames), !parameterSets.isEmpty else { continue }
            stats.frames += 1
            if firstFrame == nil { firstFrame = now() }
            lock.withLock { self.decoder }?.decode(unit.lengthPrefixedFrame)
        }
    }

    // MARK: - Asking devicectl

    /// The phone's screen size in pixels, from `devicectl device info displays`.
    private static func screenPixels(_ identifier: UUID, devicectl: Devicectl) -> Size? {
        json(devicectl, ["device", "info", "displays", "--device", identifier.uuidString, "--quiet"], named: "displays")
            .flatMap(PhysicalPhone.screenPixels(fromDisplaysJSON:))
    }

    /// The Mac's end of the phone's tunnel, once the tunnel is up: the
    /// address among `interfaces` on the prefix of the phone's tunnel
    /// address, which devicectl lists (resolving its `.coredevice.local`
    /// name instead can sit out a five-second mDNS timeout).
    private static func localTunnelAddress(_ identifier: UUID, devicectl: Devicectl, among interfaces: [String]) -> String? {
        guard let data = json(devicectl, ["list", "devices", "--quiet"], named: "tunnel"),
              let phone = try? PhysicalPhone.list(fromDevicectlJSON: data)
                .first(where: { $0.coreDeviceIdentifier == identifier }),
              let address = phone.tunnelAddress
        else { return nil }
        return TunnelAddress.local(facing: address, among: interfaces)
    }

    /// What devicectl writes with `--json-output`, read back.
    private static func json(_ devicectl: Devicectl, _ arguments: [String], named name: String) -> Data? {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("baguette-\(name)-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        guard (try? devicectl.runAndWait(arguments + ["--json-output", file.path])) != nil else { return nil }
        return try? Data(contentsOf: file)
    }

    /// A value another thread hands over once; waiting gives up after a while.
    private final class Answer<Value>: @unchecked Sendable {
        private let given = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var value: Value?
        private var waited = false

        func give(_ value: Value?) {
            lock.withLock { self.value = value }
            given.signal()
        }

        func wait(upTo seconds: Double) -> Value? {
            let first = lock.withLock { defer { waited = true }; return !waited }
            if first { _ = given.wait(timeout: .now() + seconds) }
            return lock.withLock { value }
        }
    }

    enum StreamError: Error {
        case notListed, noTunnel, unexpectedAnswer, silent
    }
}
