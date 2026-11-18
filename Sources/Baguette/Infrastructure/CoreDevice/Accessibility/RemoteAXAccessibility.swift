import Foundation

/// A physical phone's accessibility tree, read from its own accessibility
/// service over the CoreDevice tunnel, the way Xcode's Accessibility
/// Inspector does:
///
/// 1. the phone's service directory (the port `remoted` holds open to it,
///    read from `nettop`) lists `remoteAXService`'s port (RemoteXPC);
/// 2. over DTX, `clientNeedsAccessibility:` asks the phone for its tree,
///    which it pushes as two `processDataFromRemoteDevice:` messages;
/// 3. the second push — every answer the phone's service gave — answers
///    Apple's translator (`AXPTranslatorBridge`), which builds the same
///    element tree a simulator's does, walked into an `AXNode`.
///
/// Integration-only; the formats are pure values in `Domain/CoreDevice`.
/// Research: docs/features/real-devices/design.md.
final class RemoteAXAccessibility: Accessibility, @unchecked Sendable {
    private static let service = "com.apple.accessibility.axAuditDaemon.remoteAXService"
    private let identifier: UUID
    private let devicectl: Devicectl
    /// A tree takes about a second, plus ~15–45 ms an element.
    private let budget: TimeInterval

    enum Failure: Error, CustomStringConvertible {
        case noTunnel, noDirectory, noService, noTree, translatorUnavailable

        var description: String {
            switch self {
            case .noTunnel: "the phone's CoreDevice tunnel isn't up"
            case .noDirectory: "the phone's service directory isn't reachable (remoted holds no connection to it)"
            case .noService: "the phone doesn't offer its accessibility service"
            case .noTree: "the phone sent no accessibility tree; dismiss any alert on it and try again"
            case .translatorUnavailable: "AccessibilityPlatformTranslation isn't available on this Mac"
            }
        }
    }

    init(identifier: UUID, devicectl: Devicectl = Devicectl(), budget: TimeInterval = 20) {
        self.identifier = identifier
        self.devicectl = devicectl
        self.budget = budget
    }

    func describeAll() throws -> AXNode? { try tree() }
    func glance() throws -> AXNode? { try tree() }
    func wake() throws {}
    func describeAt(point: Point) throws -> AXNode? { try tree()?.hitTest(point) }

    /// Pressing through accessibility needs a live request the phone answers;
    /// not wired yet, so nothing is pressed.
    func press(_ node: AXNode) throws -> Bool { false }

    // MARK: - The tree

    /// One read per phone at a time: its accessibility service closes a
    /// second session, so callers that overlap share the one in flight.
    private func tree() throws -> AXNode? {
        try Self.sharedRead(for: identifier).read { try readTree() }
    }

    private static let readsLock = NSLock()
    nonisolated(unsafe) private static var reads: [UUID: SharedRead<AXNode?>] = [:]

    private static func sharedRead(for phone: UUID) -> SharedRead<AXNode?> {
        readsLock.withLock {
            if let read = reads[phone] { return read }
            let read = SharedRead<AXNode?>()
            reads[phone] = read
            return read
        }
    }

    private func readTree() throws -> AXNode? {
        guard let translator = AXPTranslatorBridge.translator else { throw Failure.translatorUnavailable }
        let deadline = Date().addingTimeInterval(budget)
        let address = try tunnelAddress()
        guard let directoryPort = ServiceDirectory.port(fromNettop: Self.nettop(), phone: address) else {
            throw Failure.noDirectory
        }
        let directory = try Self.directory(at: address, port: directoryPort, by: deadline)
        guard let port = directory.ports[Self.service] else { throw Failure.noService }
        let dump = try Self.treeDump(at: address, port: port, by: deadline)

        // One token per phone, pointed at its newest tree: the translator
        // caches the elements it builds, each still carrying the token it was
        // built with, so a fresh token per read leaves a long-lived process
        // (`serve`) asking a dead token — an empty app on every later read.
        let token = "baguette-phone-\(identifier.uuidString)"
        AXPTranslatorBridge.dispatcher.register(token: token, deadline: .distantFuture) { request in
            Self.respond(to: request, from: dump)
        }
        dump.root.setValue(token, forKey: "bridgeDelegateToken")
        guard let element = AXPTranslatorBridge.macPlatformElement(translator: translator, translation: dump.root) else {
            return nil
        }
        return AXNode.walk(from: element, transform: AXFrameTransform(pointSize: .zero, orientation: .portrait),
                           deadline: deadline).onItsAppsScreen
    }

    /// The translator's request, answered from the phone's pushed tree.
    private static func respond(to request: AnyObject, from dump: AXTreeDump) -> AnyObject? {
        guard let request = request as? NSObject else { return nil }
        let number = { (key: String) in (request.value(forKey: key) as? NSNumber)?.uint64Value ?? 0 }
        let answer = dump.answer(type: number("requestType"), attribute: number("attributeType"),
                                 element: request.value(forKey: "translation") as? NSObject)
        switch answer {
        case let .response(response)?:
            return response
        case let .value(attribute, value)?:
            let response = newResponse()
            response?.setValue(NSNumber(value: attribute), forKey: "attribute")
            response?.setValue(value, forKey: "resultData")
            return response
        case let .values(values)?:
            let response = newResponse()
            response?.setValue(NSDictionary(dictionary: values), forKey: "resultData")
            return response
        case nil:
            return nil
        }
    }

    private static func newResponse() -> NSObject? {
        (NSClassFromString("AXPTranslatorResponse") as? NSObject.Type)?.init()
    }

    // MARK: - Reaching the phone

    /// The phone's end of the CoreDevice tunnel, bringing the tunnel up
    /// (a devicectl info query does) when it's down.
    private func tunnelAddress() throws -> String {
        if let address = listedTunnelAddress() { return address }
        _ = try? devicectl.runAndWait(["device", "info", "details", "--device", identifier.uuidString, "--quiet"])
        guard let address = listedTunnelAddress() else { throw Failure.noTunnel }
        return address
    }

    private func listedTunnelAddress() -> String? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("baguette-ax-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        guard (try? devicectl.runAndWait(["list", "devices", "--quiet", "--json-output", file.path])) != nil,
              let data = try? Data(contentsOf: file),
              let phone = try? PhysicalPhone.list(fromDevicectlJSON: data).first(where: { $0.coreDeviceIdentifier == identifier })
        else { return nil }
        return phone.tunnelAddress
    }

    /// `remoted`'s TCP connections, as nettop lists them.
    private static func nettop() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-L", "1", "-m", "tcp", "-n", "-x", "-p", "remoted", "-J", "state"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self)
    }

    /// The service directory's handshake, over RemoteXPC (HTTP/2).
    private static func directory(at address: String, port: UInt16, by deadline: Date) throws -> ServiceDirectory {
        let socket = try TunnelSocket(host: address, port: port, timeout: 5)
        try socket.write(HTTP2Frame.remoteXPCOpening)
        var stream = Data()
        while true {
            guard let header = HTTP2Frame.Header(try socket.read(9, by: deadline)) else { throw Failure.noDirectory }
            let payload = header.length > 0 ? try socket.read(header.length, by: deadline) : Data()
            switch HTTP2Frame.Kind(rawValue: header.type) {
            case .settings? where header.flags & 0x1 == 0:
                try socket.write(HTTP2Frame(type: .settings, flags: 0x1).bytes)
            case .ping? where header.flags & 0x1 == 0:
                try socket.write(HTTP2Frame(type: .ping, flags: 0x1, payload: payload).bytes)
            case .data? where header.stream == 1:
                stream += payload
                while let (message, length) = try XPCMessage.read(from: stream) {
                    stream = Data(stream.dropFirst(length))
                    if let body = message.body, let directory = ServiceDirectory(handshake: body) { return directory }
                }
            case .goAway?:
                throw Failure.noDirectory
            default:
                continue
            }
        }
    }

    /// Asks the accessibility service for its tree and waits for the push
    /// that completes it.
    private static func treeDump(at address: String, port: UInt16, by deadline: Date) throws -> AXTreeDump {
        let socket = try TunnelSocket(host: address, port: port, timeout: 5)
        let next = { (count: Int) in try socket.read(count, by: deadline) }
        try socket.write(DTXMessage.call("_notifyOfPublishedCapabilities:", argument: [
            "com.apple.private.DTXBlockCompression": NSNumber(value: 0),
            "com.apple.private.DTXConnection": NSNumber(value: 1),
        ] as NSDictionary, id: 1).bytes)
        let capabilities = try DTXMessage.read(next)
        if capabilities.expectsReply { try socket.write(capabilities.acknowledgement.bytes) }
        try socket.write(DTXMessage.call("clientNeedsAccessibility:", argument: NSNumber(value: true), id: 2).bytes)
        defer { try? socket.write(DTXMessage.call("clientNeedsAccessibility:", argument: NSNumber(value: false), id: 3).bytes) }
        while true {
            let message: DTXMessage
            do { message = try DTXMessage.read(next) } catch TunnelSocket.Failure.timedOut { throw Failure.noTree }
            if message.expectsReply, message.conversation == 0 { try socket.write(message.acknowledgement.bytes) }
            guard message.selector == "processDataFromRemoteDevice:",
                  let archive = try? message.argument(of: NSData.self),
                  let envelope = unarchive(archive as Data),
                  let dump = AXTreeDump(envelope: envelope), dump.isComplete
            else { continue }
            return dump
        }
    }

    /// The phone's `AXPTranslatorResponse`, decoded with the translator's own
    /// classes (loaded with `AXPTranslatorBridge`).
    private static func unarchive(_ data: Data) -> NSObject? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = false
        defer { unarchiver.finishDecoding() }
        return unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSObject
    }
}
