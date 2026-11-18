import Foundation
import IOSurface

/// A physical phone's live screen: the HEVC stream the phone itself
/// encodes, started through CoreDevice and received here as RTP over the
/// CoreDevice tunnel — the stream Device Hub shows, without AVConference's
/// receiver (which only Apple's apps may use). About 60 fps.
///
/// Integration-only: the packets, frames and RTCP are pure values
/// (`MediaStreamPackets.swift`), and decoding is `H264Decoder`'s. When the
/// stream can't start, the screen falls back to `fallback` (screenshots).
final class MediaStreamScreen: Screen, @unchecked Sendable {
    private let identifier: UUID
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
         makeDecoder: @escaping @Sendable () -> any StreamDecoder = { VTStreamDecoder() },
         fallback: any Screen) {
        self.identifier = identifier
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
        let offer = try AVConferenceNegotiator.videoOffer()

        let identifier = self.identifier
        let response = try device.startMediaStream {
            guard let local = Self.localTunnelAddress(identifier) else { throw StreamError.noTunnel }
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

        try receive(on: fd, phone: phone, reporter: ourSSRC, source: phoneSSRC, onFrame)
    }

    private func receive(on fd: Int32, phone: sockaddr_in6, reporter: UInt32, source: UInt32,
                         _ onFrame: @escaping @Sendable (IOSurface) -> Void) throws {
        var phone = phone
        // The phone answers AVConference's offer with HEVC.
        var depacketizer = VideoDepacketizer(codec: .hevc)
        var parameterSets: [Data] = []
        var highest: UInt32 = 0
        var lastReport = Date.distantPast
        var firstPacket: Date?
        var keyframes = 0
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let opened = Date()
        send(RTCPReceiverReport.pictureLossIndication(reporter: reporter, source: source), to: &phone, on: fd)

        while isRunning {
            // The phone stops streaming after 20 s without a report; send one a second.
            if Date().timeIntervalSince(lastReport) >= 1 {
                send(RTCPReceiverReport(reporter: reporter, source: source, highestSequence: highest).bytes, to: &phone, on: fd)
                if keyframes == 0 {
                    send(RTCPReceiverReport.pictureLossIndication(reporter: reporter, source: source), to: &phone, on: fd)
                }
                lastReport = Date()
            }
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else {
                if firstPacket == nil, Date().timeIntervalSince(opened) > 5 { throw StreamError.silent }
                continue
            }
            let data = Data(buffer[0..<count])
            guard !RTPPacket.isRTCP(data), let packet = RTPPacket(data) else { continue }
            if firstPacket == nil { firstPacket = Date() }
            highest = max(highest, highest & 0xFFFF_0000 | UInt32(packet.sequence))
            guard let unit = depacketizer.push(packet) else { continue }
            let fresh = unit.parameterSets
            if !fresh.isEmpty, fresh != parameterSets {
                let decoder = lock.withLock { self.decoder } ?? makeDecoder()
                try decoder.configure(codec: unit.codec, parameterSets: fresh, onFrame: onFrame)
                lock.withLock { self.decoder = decoder }
                parameterSets = fresh
            }
            if unit.isKeyframe { keyframes += 1 }
            guard !parameterSets.isEmpty, keyframes > 0 else { continue }
            lock.withLock { self.decoder }?.decode(unit.lengthPrefixedFrame)
        }
    }

    // MARK: - Pieces

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
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
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

    /// The Mac's end of the phone's tunnel, once the tunnel is up.
    private static func localTunnelAddress(_ identifier: UUID) -> String? {
        guard let phone = resolve("\(identifier.uuidString).coredevice.local").first else { return nil }
        return TunnelAddress.local(facing: phone, among: interfaceAddresses())
    }

    private static func resolve(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_INET6
        var results: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &results) == 0 else { return [] }
        defer { freeaddrinfo(results) }
        var addresses: [String] = []
        var cursor = results
        while let entry = cursor {
            addresses.append(numericHost(entry.pointee.ai_addr, entry.pointee.ai_addrlen))
            cursor = entry.pointee.ai_next
        }
        return addresses
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

    enum StreamError: Error {
        case notListed, socket, noTunnel, unexpectedAnswer, silent
    }
}
