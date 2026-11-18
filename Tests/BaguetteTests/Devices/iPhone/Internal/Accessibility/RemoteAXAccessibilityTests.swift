import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// Answers KVC from a dictionary and keeps what is set on it, as
/// AccessibilityPlatformTranslation's request and response objects do.
private final class FakeAX: NSObject, @unchecked Sendable {
    var values: [String: Any]
    init(_ values: [String: Any] = [:]) { self.values = values }
    override func value(forKey key: String) -> Any? { values[key] }
    override func setValue(_ value: Any?, forKey key: String) { values[key] = value }
}

/// A phone's accessibility tree read over its tunnel, with the phone's two
/// services, devicectl, nettop and Apple's translator stood in for.
@Suite("RemoteAXAccessibility")
struct RemoteAXAccessibilityTests {
    private static let directoryPort: UInt16 = 55478
    private static let axPort: UInt16 = 61501
    private static let nettop =
        "tcp6 \(PhoneJSON.mac).51508<->\(PhoneJSON.tunnel).\(directoryPort),Established,\n"
    private static let axService = "com.apple.accessibility.axAuditDaemon.remoteAXService"
    private static let node = AXNode(role: "AXApplication", frame: Rect(origin: Point(x: 0, y: 0), size: Size(width: 440, height: 956)),
                                     children: [AXNode(role: "AXButton", label: "New Project",
                                                       frame: Rect(origin: Point(x: 20, y: 100), size: Size(width: 100, height: 44)))])

    /// One of the phone's services: hands out what the phone sends, keeps
    /// what is written to it, and times out once the phone has said it all.
    private final class Service: @unchecked Sendable {
        let connection = MockTunnelConnection()
        private let lock = NSLock()
        private var inbound: Data
        private var _written: [Data] = []
        var written: [Data] { lock.withLock { _written } }

        init(_ inbound: Data) {
            self.inbound = inbound
            given(connection).write(.any).willProduce { [self] data in lock.withLock { _written.append(data) } }
            given(connection).read(.any, by: .any).willProduce { [self] count, _ in
                try lock.withLock {
                    guard self.inbound.count >= count else { throw TunnelSocket.Failure.timedOut }
                    defer { self.inbound = Data(self.inbound.dropFirst(count)) }
                    return Data(self.inbound.prefix(count))
                }
            }
        }
    }

    /// The directory's side of RemoteXPC: settings and a ping to answer,
    /// then the handshake listing `services`.
    private static func directory(offering services: [String: XPCObject]) -> Data {
        let handshake = XPCObject.dictionary([
            "MessageType": .string("Handshake"),
            "Properties": .dictionary(["UniqueDeviceID": .string("00008160-001239C43AA0000A")]),
            "Services": .dictionary(services),
        ])
        return HTTP2Frame(type: .settings).bytes
            + HTTP2Frame(type: .ping, payload: Data([1, 2, 3, 4, 5, 6, 7, 8])).bytes
            + HTTP2Frame(type: .windowUpdate, payload: Data([0, 0, 0, 1])).bytes
            + HTTP2Frame(type: .data, stream: 1, payload: XPCMessage(flags: 1, id: 1, body: .dictionary(["MessageType": .string("Heartbeat")])).bytes).bytes
            + HTTP2Frame(type: .data, stream: 1, payload: XPCMessage(flags: 1, id: 2, body: handshake).bytes).bytes
    }

    private static let offered: [String: XPCObject] = [axService: .dictionary(["Port": .string("\(axPort)")])]

    /// The app's button, as the phone names its elements.
    nonisolated(unsafe) private static let app: NSDictionary = ["pid": NSNumber(value: 812), "objectID": NSNumber(value: 1)]
    nonisolated(unsafe) private static let button: NSDictionary = ["pid": NSNumber(value: 812), "objectID": NSNumber(value: 42)]
    nonisolated(unsafe) private static let rootRecord: NSDictionary = ["associatedRequestType": NSNumber(value: 4), "translationResponse": app]

    /// One push of the phone's tree, archived as the phone sends it.
    private static func push(_ kind: String, id: UInt32) throws -> Data {
        let records: [NSDictionary] = [
            rootRecord,
            ["associatedRequestType": NSNumber(value: 5), "associatedTranslationObject": button,
             "resultData": [NSNumber(value: 2001): "New Project"] as NSDictionary],
        ]
        let envelope: NSDictionary = ["resultData": ["treeDumpType": kind, "treeDump": records] as NSDictionary]
        let archive = try NSKeyedArchiver.archivedData(withRootObject: envelope, requiringSecureCoding: false)
        return try DTXMessage.call("processDataFromRemoteDevice:", argument: archive as NSData, id: id, expectsReply: true).bytes
    }

    private static let capabilities: DTXMessage = try! DTXMessage.call(
        "_notifyOfPublishedCapabilities:", argument: ["com.apple.private.DTXConnection": NSNumber(value: 1)] as NSDictionary,
        id: 1, expectsReply: true)

    /// The accessibility service's side: its capabilities, then both pushes.
    private static func axConversation(complete: Bool = true) throws -> Data {
        var bytes = try capabilities.bytes
            + push("AXPTreeDumpTypeInitialDump", id: 2)
            + DTXMessage.call("_channelCanceled:", argument: NSNumber(value: 0), id: 3).bytes
        if complete { bytes += try push("AXPTreeDumpTypeAdditionalData", id: 4) }
        return bytes
    }

    /// Everything the accessibility reader talks to, recorded.
    private final class Rig: @unchecked Sendable {
        /// Each rig its own phone: reads of one phone are shared.
        let phone = UUID()
        let translator = MockAccessibilityTranslator()
        let directory: Service
        let ax: Service
        let devicectl: FakeDevicectl
        let nettop: String
        private let lock = NSLock()
        private var _answering: (@Sendable (AnyObject) -> AnyObject?)?
        private var _root: NSObject?
        private var _token: String?
        private var _hosts: [String] = []
        var answering: (@Sendable (AnyObject) -> AnyObject?)? { lock.withLock { _answering } }
        var root: NSObject? { lock.withLock { _root } }
        var token: String? { lock.withLock { _token } }
        var hosts: [String] { lock.withLock { _hosts } }

        init(translates: Bool = true, tunnels: [String?] = [PhoneJSON.tunnel], nettop: String = RemoteAXAccessibilityTests.nettop,
             directory: Data = RemoteAXAccessibilityTests.directory(offering: RemoteAXAccessibilityTests.offered),
             ax: Data) {
            self.directory = Service(directory)
            self.ax = Service(ax)
            self.nettop = nettop
            devicectl = PhoneJSON.devicectl(listings: tunnels.map { [phone] in PhoneJSON.listing(tunnelAddress: $0, identifier: phone) })
            given(translator).isAvailable.willReturn(translates)
            given(translator).response().willProduce { FakeAX() }
            given(translator).tree(from: .any, token: .any, deadline: .any, answering: .any)
                .willProduce { [self] root, token, _, answering in
                    lock.withLock { _root = root; _token = token; _answering = answering }
                    return RemoteAXAccessibilityTests.node
                }
        }

        func accessibility() -> RemoteAXAccessibility {
            let (directory, ax, nettop) = (directory, ax, nettop)
            return RemoteAXAccessibility(
                identifier: phone, devicectl: Devicectl(makeSubprocess: devicectl.make), budget: 5,
                translator: translator,
                connect: { [self] host, port in
                    lock.withLock { _hosts.append(host) }
                    return port == RemoteAXAccessibilityTests.directoryPort ? directory.connection : ax.connection
                },
                nettop: { nettop })
        }
    }

    // MARK: - The tree

    @Test func `should read the phone's tree from the push that completes it`() throws {
        let rig = Rig(ax: try Self.axConversation())

        let tree = try rig.accessibility().describeAll()

        #expect(tree == Self.node)
        #expect(rig.root?.value(forKey: "objectID") as? NSNumber == 1)
        #expect(rig.token == "baguette-phone-\(rig.phone.uuidString)")
        #expect(rig.hosts == [PhoneJSON.tunnel, PhoneJSON.tunnel])
    }

    @Test func `should glance at the same tree it describes`() throws {
        let rig = Rig(ax: try Self.axConversation())

        #expect(try rig.accessibility().glance() == Self.node)
    }

    @Test func `should find the element at a point in the phone's tree`() throws {
        let rig = Rig(ax: try Self.axConversation())

        let found = try rig.accessibility().describeAt(point: Point(x: 50, y: 120))

        #expect(found?.label == "New Project")
    }

    @Test func `should press nothing through the phone's accessibility yet`() throws {
        let rig = Rig(ax: Data())
        let accessibility = rig.accessibility()

        try accessibility.wake()
        #expect(try !accessibility.press(Self.node))
        verify(rig.translator).isAvailable.called(0)
    }

    // MARK: - Talking to the phone

    @Test func `should open the directory's RemoteXPC and answer its settings and pings`() throws {
        let rig = Rig(ax: try Self.axConversation())

        _ = try rig.accessibility().describeAll()

        #expect(rig.directory.written == [
            HTTP2Frame.remoteXPCOpening,
            HTTP2Frame(type: .settings, flags: 0x1).bytes,
            HTTP2Frame(type: .ping, flags: 0x1, payload: Data([1, 2, 3, 4, 5, 6, 7, 8])).bytes,
        ])
    }

    @Test func `should ask the phone for its tree, acknowledge what it sends, and say when it is done`() throws {
        let rig = Rig(ax: try Self.axConversation())

        _ = try rig.accessibility().describeAll()

        let pushed = try DTXMessage.read(Self.reading(Self.push("AXPTreeDumpTypeInitialDump", id: 2)))
        let completed = try DTXMessage.read(Self.reading(Self.push("AXPTreeDumpTypeAdditionalData", id: 4)))
        #expect(rig.ax.written == [
            try DTXMessage.call("_notifyOfPublishedCapabilities:", argument: [
                "com.apple.private.DTXBlockCompression": NSNumber(value: 0),
                "com.apple.private.DTXConnection": NSNumber(value: 1),
            ] as NSDictionary, id: 1).bytes,
            Self.capabilities.acknowledgement.bytes,
            try DTXMessage.call("clientNeedsAccessibility:", argument: NSNumber(value: true), id: 2).bytes,
            pushed.acknowledgement.bytes,
            completed.acknowledgement.bytes,
            try DTXMessage.call("clientNeedsAccessibility:", argument: NSNumber(value: false), id: 3).bytes,
        ])
    }

    private static func reading(_ data: Data) -> (Int) throws -> Data {
        var rest = data
        return { count in defer { rest = Data(rest.dropFirst(count)) }; return Data(rest.prefix(count)) }
    }

    // MARK: - Answering the translator

    @Test func `should answer the translator's question about one attribute from the phone's tree`() throws {
        let rig = Rig(ax: try Self.axConversation())
        _ = try rig.accessibility().describeAll()
        let request = FakeAX(["requestType": NSNumber(value: 2), "attributeType": NSNumber(value: 2001), "translation": Self.button])

        let response = try #require(rig.answering?(request) as? FakeAX)

        #expect(response.values["attribute"] as? NSNumber == 2001)
        #expect(response.values["resultData"] as? String == "New Project")
    }

    @Test func `should answer the translator's question about every attribute at once`() throws {
        let rig = Rig(ax: try Self.axConversation())
        _ = try rig.accessibility().describeAll()
        let request = FakeAX(["requestType": NSNumber(value: 5), "translation": Self.button])

        let response = try #require(rig.answering?(request) as? FakeAX)

        #expect(response.values["resultData"] as? NSDictionary == [NSNumber(value: 2001): "New Project"] as NSDictionary)
    }

    @Test func `should answer the translator with the phone's own response where it has one`() throws {
        let rig = Rig(ax: try Self.axConversation())
        _ = try rig.accessibility().describeAll()
        let request = FakeAX(["requestType": NSNumber(value: 4)])

        let response = rig.answering?(request) as? NSDictionary

        #expect(response == Self.rootRecord)
    }

    @Test func `should answer the translator with nothing the phone didn't push`() throws {
        let rig = Rig(ax: try Self.axConversation())
        _ = try rig.accessibility().describeAll()
        let request = FakeAX(["requestType": NSNumber(value: 2), "attributeType": NSNumber(value: 9999), "translation": Self.button])

        #expect(rig.answering?(request) == nil)
    }

    // MARK: - When it can't

    @Test func `should fail when this Mac has no accessibility translator`() throws {
        let rig = Rig(translates: false, ax: try Self.axConversation())

        #expect(throws: RemoteAXAccessibility.Failure.translatorUnavailable) { try rig.accessibility().describeAll() }
        #expect(rig.devicectl.arguments.isEmpty)
    }

    @Test func `should bring the phone's tunnel up when devicectl lists it down`() throws {
        let rig = Rig(tunnels: [nil, PhoneJSON.tunnel], ax: try Self.axConversation())

        #expect(try rig.accessibility().describeAll() == Self.node)
        #expect(rig.devicectl.arguments.contains(
            ["devicectl", "device", "info", "details", "--device", rig.phone.uuidString, "--quiet"]))
    }

    @Test func `should fail when the phone's tunnel stays down`() throws {
        let rig = Rig(tunnels: [nil], ax: try Self.axConversation())

        #expect(throws: RemoteAXAccessibility.Failure.noTunnel) { try rig.accessibility().describeAll() }
    }

    @Test func `should fail when remoted holds no connection to the phone's service directory`() throws {
        let rig = Rig(nettop: "", ax: try Self.axConversation())

        #expect(throws: RemoteAXAccessibility.Failure.noDirectory) { try rig.accessibility().describeAll() }
        #expect(rig.hosts.isEmpty)
    }

    @Test func `should fail when the directory goes away before its handshake`() throws {
        let rig = Rig(directory: HTTP2Frame(type: .goAway).bytes, ax: try Self.axConversation())

        #expect(throws: RemoteAXAccessibility.Failure.noDirectory) { try rig.accessibility().describeAll() }
    }

    @Test func `should fail when the directory stops talking before its handshake`() throws {
        let rig = Rig(directory: Data([0, 0]), ax: try Self.axConversation())

        #expect(throws: TunnelSocket.Failure.self) { try rig.accessibility().describeAll() }
    }

    @Test func `should fail when the phone doesn't offer its accessibility service`() throws {
        let rig = Rig(directory: Self.directory(offering: [:]), ax: try Self.axConversation())

        #expect(throws: RemoteAXAccessibility.Failure.noService) { try rig.accessibility().describeAll() }
    }

    @Test func `should fail when the phone sends no accessibility tree`() throws {
        let rig = Rig(ax: try Self.axConversation(complete: false))

        #expect(throws: RemoteAXAccessibility.Failure.noTree) { try rig.accessibility().describeAll() }
        verify(rig.translator).tree(from: .any, token: .any, deadline: .any, answering: .any).called(0)
    }
}
