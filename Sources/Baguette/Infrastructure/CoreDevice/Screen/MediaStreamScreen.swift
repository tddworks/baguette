import Foundation
import IOSurface

/// A physical phone's live screen: the H.264 stream the phone itself
/// encodes, started through CoreDevice with our own offer
/// (`MediaStreamOffer`) and received here as RTP over the CoreDevice
/// tunnel, without AVConference's receiver (which only Apple's apps may
/// use). About 60 fps.
///
/// Integration-only: the packets, frames and RTCP are pure values
/// (`MediaStreamPackets.swift`), and decoding is `H264Decoder`'s. When the
/// stream can't start, the screen falls back to `fallback` (screenshots).
final class MediaStreamScreen: Screen, @unchecked Sendable {
    private let identifier: UUID
    private let devicectl: Devicectl
    private let makeDecoder: @Sendable () -> any StreamDecoder
    private let fallback: any Screen
    private let lock = NSLock()
    private var running = false
    private var socket: Int32 = -1
    private var phone: sockaddr_in6?
    private var reporter: UInt32 = 0
    private var source: UInt32 = 0
    private var decoder: (any StreamDecoder)?
    private var usingFallback = false

    init(identifier: UUID,
         devicectl: Devicectl = Devicectl(),
         makeDecoder: @escaping @Sendable () -> any StreamDecoder = { VTStreamDecoder() },
         fallback: any Screen) {
        self.identifier = identifier
        self.devicectl = devicectl
        self.makeDecoder = makeDecoder
        self.fallback = fallback
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
        let (fd, phone, reporter, decoder, fellBack) = lock.withLock {
            running = false
            defer { socket = -1; self.decoder = nil }
            return (socket, self.phone, self.reporter, self.decoder, usingFallback)
        }
        if fd >= 0 {
            if var phone { send(Self.goodbye(reporter), to: &phone, on: fd) }
            close(fd)
        }
        decoder?.stop()
        if fellBack { fallback.stop() }
    }

    private var isRunning: Bool { lock.withLock { running } }

    // MARK: - The stream

    private func stream(_ onFrame: @escaping @Sendable (IOSurface) -> Void) throws {
        guard let device = CoreDeviceFramework.device(identifier) else { throw StreamError.notListed }
        let fd = try Self.receiver()
        lock.withLock { socket = fd }
        let port = Self.port(of: fd)
        let offer = MediaStreamOffer(
            receiver: UInt32.random(in: 1 ... .max), host: Self.mac, made: Self.ntpNow()).bytes

        let identifier = self.identifier, devicectl = self.devicectl
        // Asked while the stream starts: the size its pictures are cropped to.
        let screenSize = Answer<Size>()
        Thread.detachNewThread { screenSize.give(Self.screenPixels(identifier, devicectl: devicectl)) }
        let response = try device.startMediaStream {
            guard let local = Self.localTunnelAddress(identifier, devicectl: devicectl) else { throw StreamError.noTunnel }
            return Self.startRequest(offer: offer, receiverIP: local, port: port)
        }

        guard let connection = response["connection"] as? [String: Any],
              let config = connection["streamConfig"] as? [String: Any],
              let sourceIP = config["SourceIP"] as? String,
              let sourcePort = (config["SourcePort"] as? NSNumber)?.uint16Value,
              let phoneSSRC = (config["LocalSSRC"] as? NSNumber)?.uint32Value,
              let ourSSRC = (config["RemoteSSRC"] as? NSNumber)?.uint32Value
        else { throw StreamError.unexpectedAnswer }
        var phone = sockaddr_in6()
        phone.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        phone.sin6_family = sa_family_t(AF_INET6)
        phone.sin6_port = sourcePort.bigEndian
        inet_pton(AF_INET6, sourceIP, &phone.sin6_addr)
        lock.withLock { self.phone = phone; reporter = ourSSRC; source = phoneSSRC }

        try receive(on: fd, phone: phone, reporter: ourSSRC, source: phoneSSRC,
                    screen: { screenSize.wait(upTo: 3) }, onFrame)
    }

    private func receive(on fd: Int32, phone: sockaddr_in6, reporter: UInt32, source: UInt32,
                         screen: () -> Size?, _ onFrame: @escaping @Sendable (IOSurface) -> Void) throws {
        var phone = phone
        var depacketizer = VideoDepacketizer()
        var feedback = ReceiverFeedback(reporter: reporter, source: source)
        var gate = DecodeGate()
        var parameterSets: [Data] = []
        var firstPacket: Date?
        var stats = (packets: 0, frames: 0, since: Date())
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let opened = Date()
        while isRunning {
            for report in feedback.due(at: Date().timeIntervalSince(opened), wantingKeyframe: gate.needsKeyframe) {
                send(report, to: &phone, on: fd)
            }
            if Date().timeIntervalSince(stats.since) >= 5 {
                log("[coredevice] stream: \(stats.packets) packets, \(stats.frames) frames, "
                    + "\(depacketizer.droppedFrames) dropped in all")
                stats = (0, 0, Date())
            }
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else {
                if firstPacket == nil, Date().timeIntervalSince(opened) > 5 { throw StreamError.silent }
                continue
            }
            let data = Data(buffer[0..<count])
            guard !RTPPacket.isRTCP(data), let packet = RTPPacket(data) else { continue }
            if firstPacket == nil { firstPacket = Date() }
            stats.packets += 1
            for report in feedback.heard(packet) { send(report, to: &phone, on: fd) }
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
            lock.withLock { self.decoder }?.decode(unit.lengthPrefixedFrame)
        }
    }

    // MARK: - Pieces

    /// This Mac, as the offer names it.
    private static var mac: MediaStreamOffer.Mac {
        MediaStreamOffer.Mac(model: sysctl("hw.model"), build: sysctl("kern.osversion"))
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return "" }
        return String(cString: bytes)
    }

    /// Now, as an NTP timestamp (seconds since 1900, 32.32 fixed point).
    private static func ntpNow() -> UInt64 {
        let now = Date().timeIntervalSince1970 + 2_208_988_800
        return UInt64(now) << 32 | UInt64((now - now.rounded(.down)) * 4_294_967_296)
    }

    private static func startRequest(offer: Data, receiverIP: String, port: UInt16) -> [String: Any] {
        [
            "timeout": 20, "type": "video", "direction": "output",
            "negotiatorOffer": offer.base64EncodedString(), "clientSupportedFeatures": 140,
            "receiverIP": receiverIP, "receiverPort": Int(port),
            "options": [
                "CoreDeviceVideoDisplayMode": ["string": "DisplayByID"],
                "VideoStreamForDisplayID": ["int": 1],
                "AVCMediaStreamNegotiatorAccessNetworkType": ["int": 1],
                "AVCMediaStreamNegotiatorTransportProtocolType": ["int": 2],
                "avcMediaStreamOptionClientSessionID": ["uuid": UUID().uuidString],
            ],
        ]
    }

    /// An RTCP BYE from our source: the phone can stop sending at once.
    private static func goodbye(_ reporter: UInt32) -> Data {
        [0x81CB_0001, reporter].map(\.bigEndian).withUnsafeBytes { Data($0) }
    }

    private static func receiver() throws -> Int32 {
        let fd = Darwin.socket(AF_INET6, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw StreamError.socket }
        var size: Int32 = 8 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 20_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_addr = in6addr_any
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        guard bound == 0 else { close(fd); throw StreamError.socket }
        return fd
    }

    private static func port(of fd: Int32) -> UInt16 {
        var address = sockaddr_in6()
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return UInt16(bigEndian: address.sin6_port)
    }

    private func send(_ data: Data, to phone: inout sockaddr_in6, on fd: Int32) {
        _ = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &phone) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
    }

    /// The phone's screen size in pixels, from `devicectl device info displays`.
    private static func screenPixels(_ identifier: UUID, devicectl: Devicectl) -> Size? {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("baguette-displays-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        guard (try? devicectl.runAndWait([
            "device", "info", "displays", "--device", identifier.uuidString, "--quiet", "--json-output", file.path,
        ])) != nil, let data = try? Data(contentsOf: file) else { return nil }
        return PhysicalPhone.screenPixels(fromDisplaysJSON: data)
    }

    /// The Mac's end of the phone's tunnel, once the tunnel is up: the
    /// local address on the prefix of the phone's tunnel address, which
    /// devicectl lists (resolving its `.coredevice.local` name instead can
    /// sit out a five-second mDNS timeout).
    private static func localTunnelAddress(_ identifier: UUID, devicectl: Devicectl) -> String? {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("baguette-tunnel-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        guard (try? devicectl.runAndWait(["list", "devices", "--quiet", "--json-output", file.path])) != nil,
              let data = try? Data(contentsOf: file),
              let phone = try? PhysicalPhone.list(fromDevicectlJSON: data)
                .first(where: { $0.coreDeviceIdentifier == identifier }),
              let address = phone.tunnelAddress
        else { return nil }
        return TunnelAddress.local(facing: address, among: interfaceAddresses())
    }

    private static func interfaceAddresses() -> [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return [] }
        defer { freeifaddrs(interfaces) }
        var addresses: [String] = []
        var cursor = interfaces
        while let entry = cursor {
            if let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET6) {
                addresses.append(numericHost(address, socklen_t(MemoryLayout<sockaddr_in6>.size)))
            }
            cursor = entry.pointee.ifa_next
        }
        return addresses
    }

    private static func numericHost(_ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> String {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        return String(cString: host)
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
        case notListed, socket, noTunnel, unexpectedAnswer, silent
    }
}
