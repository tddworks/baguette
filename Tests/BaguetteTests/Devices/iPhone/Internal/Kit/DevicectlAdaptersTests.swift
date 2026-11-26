import Foundation
import IOSurface
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// A `Subprocess` stand-in for `xcrun devicectl`: records every argv and
/// stdin, answers each run with `output` and `status`, and can write a
/// file where devicectl would (`--json-output`, `--destination`).
final class FakeDevicectl: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var runs: [(arguments: [String], stdin: String?)] = []
    var status: Int32 = 0
    var output = Data()
    var writeFile: ((_ path: String, _ arguments: [String]) -> Void)?

    func make() -> any Subprocess {
        let sub = MockSubprocess()
        given(sub).run(executable: .any, arguments: .any, onBytes: .any, onExit: .any)
            .willProduce { [self] _, arguments, onBytes, onExit in
                answer(arguments, stdin: nil, onBytes, onExit)
            }
        given(sub).run(executable: .any, arguments: .any, stdin: .any, onBytes: .any, onExit: .any)
            .willProduce { [self] _, arguments, stdin, onBytes, onExit in
                answer(arguments, stdin: String(decoding: stdin, as: UTF8.self), onBytes, onExit)
            }
        given(sub).terminate().willReturn()
        return sub
    }

    var arguments: [[String]] { lock.withLock { runs.map(\.arguments) } }

    private func answer(
        _ arguments: [String], stdin: String?,
        _ onBytes: @Sendable (Data) -> Void, _ onExit: @Sendable (Int32) -> Void
    ) {
        lock.withLock { runs.append((arguments, stdin)) }
        for flag in ["--json-output", "--destination"] {
            if let index = arguments.firstIndex(of: flag), index + 1 < arguments.count {
                writeFile?(arguments[index + 1], arguments)
            }
        }
        if !output.isEmpty { onBytes(output) }
        onExit(status)
    }
}

private let phoneUDID = "00008160-001239C43AA0000A"

@Suite("Devicectl")
struct DevicectlTests {
    @Test func `should run devicectl through xcrun and hand back what it printed`() async throws {
        let fake = FakeDevicectl()
        fake.output = Data("Current Device Orientation: portrait\n".utf8)

        let output = try await Devicectl(makeSubprocess: fake.make).run(["device", "orientation", "get"])

        #expect(fake.arguments == [["devicectl", "device", "orientation", "get"]])
        #expect(String(decoding: output, as: UTF8.self) == "Current Device Orientation: portrait\n")
    }

    @Test func `should fail with devicectl's last words when it exits non-zero`() async {
        let fake = FakeDevicectl()
        fake.status = 1
        fake.output = Data("Error: one\nERROR: The device is locked.\n".utf8)

        await #expect(throws: DevicectlError.failed(status: 1, message: "ERROR: The device is locked.")) {
            try await Devicectl(makeSubprocess: fake.make).run(["device", "info", "details"])
        }
    }

    @Test func `should report devicectl when it can't even start`() async {
        struct NoXcrun: Error, Equatable {}
        let sub = MockSubprocess()
        given(sub).run(executable: .any, arguments: .any, onBytes: .any, onExit: .any).willThrow(NoXcrun())

        await #expect(throws: NoXcrun()) {
            try await Devicectl(makeSubprocess: { sub }).run(["list", "devices"])
        }
    }

    @Test func `should keep devicectl's process alive until it exits`() async throws {
        let exit = ExitLatch()
        let devicectl = Devicectl(makeSubprocess: {
            let sub = MockSubprocess()
            given(sub).run(executable: .any, arguments: .any, onBytes: .any, onExit: .any)
                .willProduce { _, _, _, onExit in exit.hold(onExit) }
            exit.track(sub)
            return sub
        })

        let task = Task { try await devicectl.run(["list", "devices"]) }
        // Fire only once devicectl's exit callback is registered; a run that
        // never registers one fails here rather than hanging the test.
        try await waitUntil { exit.isHeld }
        try #require(exit.isHeld)
        #expect(exit.subprocessAlive)

        exit.fire(0)
        _ = try await task.value
    }

    @Test func `should run devicectl to the end when the caller can't wait asynchronously`() throws {
        let fake = FakeDevicectl()
        fake.output = Data("done".utf8)

        let output = try Devicectl(makeSubprocess: fake.make).runAndWait(["list", "devices"])

        #expect(String(decoding: output, as: UTF8.self) == "done")
    }
}

@Suite("DevicectlPasteboard")
struct DevicectlPasteboardTests {
    @Test func `should put text on the phone's pasteboard through devicectl's stdin`() async throws {
        let fake = FakeDevicectl()

        try await DevicectlPasteboard(udid: phoneUDID, devicectl: Devicectl(makeSubprocess: fake.make))
            .setText("héllo")

        #expect(fake.runs.map(\.arguments) == [["devicectl", "device", "pasteboard", "copy", "--quiet", "--device", phoneUDID]])
        #expect(fake.runs.map(\.stdin) == ["héllo"])
    }

    @Test func `should read the text on the phone's pasteboard`() async throws {
        let fake = FakeDevicectl()
        fake.output = Data("copied on the phone".utf8)

        let text = try await DevicectlPasteboard(udid: phoneUDID, devicectl: Devicectl(makeSubprocess: fake.make)).text()

        #expect(text == "copied on the phone")
        #expect(fake.arguments == [["devicectl", "device", "pasteboard", "paste", "--quiet", "--device", phoneUDID]])
    }

    @Test func `should carry the Mac's pasteboard to the phone and back`() async throws {
        let fake = FakeDevicectl()
        let pasteboard = DevicectlPasteboard(udid: phoneUDID, devicectl: Devicectl(makeSubprocess: fake.make))

        try await pasteboard.syncFromHost()
        try await pasteboard.syncToHost()

        #expect(fake.arguments == [
            ["devicectl", "device", "pasteboard", "transfer", "to", "--quiet", "--device", phoneUDID],
            ["devicectl", "device", "pasteboard", "transfer", "from", "--quiet", "--device", phoneUDID],
        ])
    }
}

@Suite("DevicectlScreen")
struct DevicectlScreenTests {
    @Test func `should deliver each screenshot devicectl takes as a frame`() async throws {
        let fake = FakeDevicectl()
        fake.writeFile = { path, _ in FileManager.default.createFile(atPath: path, contents: Data("png".utf8)) }
        let surface = try #require(IOSurface(properties: [
            .width: 2, .height: 2, .bytesPerElement: 4, .pixelFormat: 0x42475241,
        ]))
        let screen = DevicectlScreen(
            udid: phoneUDID, devicectl: Devicectl(makeSubprocess: fake.make),
            decode: { _ in surface }, interval: 0)
        let frames = FrameCounter()

        try screen.start { _ in frames.add() }
        try await frames.wait(for: 2)
        screen.stop()

        let first = try #require(fake.arguments.first)
        #expect(Array(first.prefix(6)) == ["devicectl", "device", "capture", "screenshot", "--device", phoneUDID])
        #expect(first.last?.hasSuffix(".png") == true)
    }

    @Test func `should keep shooting after a screenshot devicectl couldn't take`() async throws {
        let fake = FakeDevicectl()
        fake.status = 1
        let screen = DevicectlScreen(
            udid: phoneUDID, devicectl: Devicectl(makeSubprocess: fake.make),
            decode: { _ in nil }, interval: 0)

        try screen.start { _ in }
        try await waitUntil { fake.arguments.count >= 2 }
        screen.stop()
    }

    @Test func `should take no more screenshots once stopped`() async throws {
        let fake = FakeDevicectl()
        let screen = DevicectlScreen(
            udid: phoneUDID, devicectl: Devicectl(makeSubprocess: fake.make),
            decode: { _ in nil }, interval: 0)

        try screen.start { _ in }
        try await waitUntil { fake.arguments.count >= 1 }
        screen.stop()
        let taken = fake.arguments.count
        try await Task.sleep(for: .milliseconds(50))

        #expect(fake.arguments.count <= taken + 1)
    }
}

@Suite("CoreDevicePhones")
struct CoreDevicePhonesTests {
    @Test func `should list the physical phones devicectl knows as devices`() throws {
        let fake = FakeDevicectl()
        fake.writeFile = { path, _ in
            FileManager.default.createFile(atPath: path, contents: Data(#"""
            {"result":{"devices":[{"connectionProperties":{"pairingState":"paired","tunnelState":"disconnected"},
             "deviceProperties":{"name":"han's iPhone","bootState":"booted","developerModeStatus":"enabled","osVersionNumber":"27.0.1"},
             "hardwareProperties":{"udid":"\#(phoneUDID)","reality":"physical","productType":"iPhone19,7",
               "marketingName":"iPhone 18 Pro Max","platform":"iOS"}}]}}
            """#.utf8))
        }
        let phones = CoreDevicePhones(devicectl: Devicectl(makeSubprocess: fake.make))

        let device = try #require(try phones.find(id: DeviceID(phoneUDID)))

        #expect(device.name == "han's iPhone")
        #expect(device.kind == DeviceKind(platform: .iOS, reality: .physical, model: "iPhone 18 Pro Max",
                                          hardware: "iPhone19,7", os: "iOS 27.0.1"))
        #expect(device.state == .ready)
        #expect(Array(fake.arguments[0].prefix(4)) == ["devicectl", "list", "devices", "--quiet"])
    }

    @Test func `should answer from its last listing while it is fresh, without asking devicectl again`() throws {
        let fake = FakeDevicectl(), now = Clock()
        fake.writeFile = { path, _ in FileManager.default.createFile(atPath: path, contents: listing("first")) }
        let phones = CoreDevicePhones(
            devicectl: Devicectl(makeSubprocess: fake.make), clock: { now.value }, refresh: { _ in })

        _ = try phones.find(id: DeviceID(phoneUDID))
        now.value += 1
        let again = try phones.find(id: DeviceID("SOME-SIMULATOR"))

        #expect(again == nil)
        #expect(fake.arguments.count == 1)
    }

    @Test func `should answer at once from a stale listing, and refresh it behind`() throws {
        let fake = FakeDevicectl(), now = Clock(), behind = Deferred()
        fake.writeFile = { path, _ in FileManager.default.createFile(atPath: path, contents: listing("first")) }
        let phones = CoreDevicePhones(
            devicectl: Devicectl(makeSubprocess: fake.make), clock: { now.value }, refresh: { behind.work.append($0) })
        _ = phones.all

        now.value += 3
        fake.writeFile = { path, _ in FileManager.default.createFile(atPath: path, contents: listing("second")) }
        let stale = try #require(try phones.find(id: DeviceID(phoneUDID)))
        #expect(stale.name == "first")
        #expect(fake.arguments.count == 1)

        behind.work.forEach { $0() }

        #expect(fake.arguments.count == 2)
        #expect(try phones.find(id: DeviceID(phoneUDID))?.name == "second")
    }

    @Test func `should keep its last listing when a refresh fails`() throws {
        let fake = FakeDevicectl(), now = Clock(), behind = Deferred()
        fake.writeFile = { path, _ in FileManager.default.createFile(atPath: path, contents: listing("first")) }
        let phones = CoreDevicePhones(
            devicectl: Devicectl(makeSubprocess: fake.make), clock: { now.value }, refresh: { behind.work.append($0) })
        _ = phones.all

        now.value += 3
        fake.status = 1
        _ = phones.all
        behind.work.forEach { $0() }

        #expect(try phones.find(id: DeviceID(phoneUDID))?.name == "first")
    }

    @Test func `should list once when the first lookups come together`() async {
        let fake = FakeDevicectl()
        fake.writeFile = { path, _ in
            usleep(50_000)   // devicectl takes its time
            FileManager.default.createFile(atPath: path, contents: listing("first"))
        }
        let phones = CoreDevicePhones(devicectl: Devicectl(makeSubprocess: fake.make), refresh: { _ in })

        await offTheTestThreads { DispatchQueue.concurrentPerform(iterations: 4) { _ in _ = phones.all } }

        #expect(fake.arguments.count == 1)
    }

    @Test func `should list no phones when devicectl can't list them`() {
        let fake = FakeDevicectl()
        fake.status = 1

        #expect(CoreDevicePhones(devicectl: Devicectl(makeSubprocess: fake.make)).all.isEmpty)
    }

    @Test func `should register what a physical phone can do, and nothing it can't`() {
        let phone = CoreDevicePhone(
            PhysicalPhone(udid: phoneUDID, name: "han's iPhone", productType: "iPhone19,7",
                          marketingName: "iPhone 18 Pro Max", platform: .iOS, state: .ready,
                          coreDeviceIdentifier: UUID()),
            devicectl: Devicectl(makeSubprocess: FakeDevicectl().make))

        #expect(phone.abilities.names == ["screen", "touch", "accessibility", "pasteboard"])
        #expect(throws: DeviceError.unable(ability: "power", device: "han's iPhone")) {
            try phone.require(.power)
        }
        #expect(throws: DeviceError.unable(ability: "key", device: "han's iPhone")) {
            try phone.require(.key)
        }
    }

    @Test func `should show a phone's live screen through CoreDevice, whichever receiver its route picks`() throws {
        for route in [PhoneScreenRoute.rtp, .avconference] {
            let phone = CoreDevicePhone(
                PhysicalPhone(udid: phoneUDID, name: "han's iPhone", productType: "iPhone19,7",
                              marketingName: "iPhone 18 Pro Max", platform: .iOS, state: .ready,
                              coreDeviceIdentifier: UUID()),
                devicectl: Devicectl(makeSubprocess: FakeDevicectl().make), screenRoute: route,
                coreDevice: reachableCoreDevice())

            let view = try #require(try phone.require(.screen) as? SharedScreenView)
            #expect(view.shared.make() is CoreDeviceScreen)
        }
    }

    // A phone streams its screen to one receiver: a second stream asked of it
    // takes the picture from the first, and its goodbye ends it for both.
    @Test func `should show every viewer of a phone one live screen, however often the phone is looked up`() throws {
        let screens = SharedScreens()
        let phone = PhysicalPhone(udid: phoneUDID, name: "han's iPhone", productType: "iPhone19,7",
                                  marketingName: "iPhone 18 Pro Max", platform: .iOS, state: .ready,
                                  coreDeviceIdentifier: UUID())
        let devicectl = Devicectl(makeSubprocess: FakeDevicectl().make)
        let coreDevice = reachableCoreDevice()
        let first = try #require(try CoreDevicePhone(phone, devicectl: devicectl, screens: screens, coreDevice: coreDevice).require(.screen) as? SharedScreenView)
        let second = try #require(try CoreDevicePhone(phone, devicectl: devicectl, screens: screens, coreDevice: coreDevice).require(.screen) as? SharedScreenView)

        #expect(first.shared === second.shared)
    }

    @Test func `should show a phone's screen as stills when this process reaches no CoreDevice`() throws {
        let phone = CoreDevicePhone(
            PhysicalPhone(udid: phoneUDID, name: "han's iPhone", productType: "iPhone19,7",
                          marketingName: "iPhone 18 Pro Max", platform: .iOS, state: .ready,
                          coreDeviceIdentifier: UUID()),
            devicectl: Devicectl(makeSubprocess: FakeDevicectl().make),
            coreDevice: .absent)

        #expect(try phone.require(.screen) is DevicectlScreen)
    }

    @Test func `should take no touch on a phone CoreDevice gave no identifier`() {
        let phone = CoreDevicePhone(
            PhysicalPhone(udid: phoneUDID, name: "han's iPhone", productType: "iPhone19,7",
                          marketingName: "iPhone 18 Pro Max", platform: .iOS, state: .ready,
                          coreDeviceIdentifier: nil),
            devicectl: Devicectl(makeSubprocess: FakeDevicectl().make))

        #expect(phone.abilities.names == ["screen", "pasteboard"])
    }
}

private final class ExitLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var onExit: (@Sendable (Int32) -> Void)?
    func hold(_ onExit: @escaping @Sendable (Int32) -> Void) { lock.withLock { self.onExit = onExit } }
    func fire(_ status: Int32) { lock.withLock { onExit }?(status) }
    var isHeld: Bool { lock.withLock { onExit != nil } }
    private weak var subprocess: AnyObject?
    func track(_ subprocess: AnyObject) { lock.withLock { self.subprocess = subprocess } }
    var subprocessAlive: Bool { lock.withLock { subprocess != nil } }
}

private final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    func wait(for target: Int) async throws {
        try await waitUntil { self.lock.withLock { self.count >= target } }
    }
}

private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(2)
    while !condition() {
        guard Date() < deadline else { Issue.record("timed out"); return }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// devicectl's list of one phone, named `name`.
private func listing(_ name: String) -> Data {
    Data(#"""
    {"result":{"devices":[{"connectionProperties":{"pairingState":"paired","tunnelState":"disconnected"},
     "deviceProperties":{"name":"\#(name)","bootState":"booted","developerModeStatus":"enabled","osVersionNumber":"27.0.1"},
     "hardwareProperties":{"udid":"\#(phoneUDID)","reality":"physical","productType":"iPhone19,7",
       "marketingName":"iPhone 18 Pro Max","platform":"iOS"}}]}}
    """#.utf8)
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var now = Date(timeIntervalSince1970: 1_000)
    var value: Date {
        get { lock.withLock { now } }
        set { lock.withLock { now = newValue } }
    }
}

/// Work handed to run in the background, run when the test says.
private final class Deferred: @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [@Sendable () -> Void] = []
    var work: [@Sendable () -> Void] {
        get { lock.withLock { queued } }
        set { lock.withLock { queued = newValue } }
    }
}

/// CoreDevice as a host that links it hands it over: it answers, and its
/// touch and screen are the fakes a test gives.
private func reachableCoreDevice(
    hid: any UniversalHID = MockUniversalHID(),
    mediaStream: any MediaStreamStarter = MockMediaStreamStarter()
) -> CoreDeviceAccess {
    CoreDeviceAccess(isAvailable: { true }, connect: { _ in }, universalHID: hid, mediaStream: mediaStream)
}
