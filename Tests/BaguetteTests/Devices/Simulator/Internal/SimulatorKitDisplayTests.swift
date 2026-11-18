import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// One display plane of a simulator: which framebuffer it binds, which
/// digitizer its input addresses, and the screen an observation reads —
/// on a phone with one panel, on a foldable whose hinge lights one of
/// two, and on CarPlay.
@Suite("SimulatorKitDisplay")
struct SimulatorKitDisplayTests {

    private static let phone = """
        Connected Screens:
        (1) LCD:
            Screen ID: 1
            Name: LCD
            Device Name: primary
            Screen Type: Integrated
            Pixel Size: {1206, 2622}
            Preferred UI Scale: 3
        """

    private static let phoneWithCarPlay = phone + """

        (2) TVOut:
            Screen ID: 2
            Name: TVOut
            Device Name: external-0
            Screen Type: TVOut
            Pixel Size: {720, 480}
        """

    /// iPhone Duo: the cover is `primary`, the unfolded panel `primary-1`.
    private static let foldable = """
        Connected Screens:
        (1) LCD:
            Screen ID: 1
            Name: LCD
            Device Name: primary
            Screen Type: Integrated
            Pixel Size: {1398, 2034}
            Preferred UI Scale: 3
        (3) LCD-1:
            Screen ID: 3
            Name: LCD-1
            Device Name: primary-1
            Screen Type: Integrated
            Pixel Size: {2007, 2853}
            Preferred UI Scale: 3
        """

    private static let open = HingeAngle(degrees: 130)

    private struct Rig {
        let device: NSObject?
        let enumerate: String
        var hinge = MockHinge()
        var guestHinge = MockHinge()
        var keys: (any DeviceKeys)? = nil
        var orientation: DeviceOrientation = .portrait
        var live = AXScreen(width: 1, height: 1, orientation: .portrait)
        var environment: [String: String] = [:]

        func display(_ kind: DisplayKind = .phone, pinned: IntegratedPanel? = nil) -> SimulatorKitDisplay {
            let host = MockDeviceHost()
            given(host).resolveDevice(udid: .any).willReturn(device)
            let enumerate = enumerate
            let orientation = orientation
            let live = live
            let environment = environment
            return SimulatorKitDisplay(
                kind: kind, udid: "U", host: host, enumerateIO: { enumerate }, hinge: hinge, keys: keys,
                pinnedPanel: pinned, guestHinge: guestHinge,
                readOrientation: { _, _ in orientation },
                readScreen: { _, _, _ in live },
                environment: { environment })
        }
    }

    private func single() -> Rig {
        Rig(device: FakeKit.device([(1206, 2622)]).0, enumerate: Self.phone)
    }

    private func carPlay() -> Rig {
        Rig(device: FakeKit.device([(1206, 2622), (720, 480)]).0, enumerate: Self.phoneWithCarPlay)
    }

    /// A foldable, with both hinges reading it open.
    private func duo(keys: (any DeviceKeys)? = nil) -> Rig {
        let rig = Rig(device: FakeKit.device([(1398, 2034), (2007, 2853)]).0, enumerate: Self.foldable, keys: keys)
        given(rig.hinge).angle().willReturn(Self.open)
        given(rig.guestHinge).angle().willReturn(Self.open)
        return rig
    }

    private func expected(_ screen: AXScreen) throws -> ExpectedScreen {
        let target = try #require(screen.target)
        let panel = target.litPanel.map { $0 == .primary ? "\"primary\"" : "\"secondary\"" } ?? "null"
        return try ExpectedScreen(json: """
            {"width": \(screen.width), "height": \(screen.height), "orientation": "\(screen.orientation.wireName)",
             "target": {"screenId": \(target.screenId), "litPanel": \(panel),
                        "pixelSize": {"width": \(Int(target.pixelSize.width)), "height": \(Int(target.pixelSize.height))}}}
            """)
    }

    // MARK: - binding

    @Test func `should bind the phone plane to the device's own screen`() throws {
        let binding = try single().display().resolve()

        #expect(binding.connectedScreenId == 1)
        #expect(binding.size == Size(width: 1206, height: 2622))
        #expect(binding.panel == .primary)
    }

    @Test func `should not ask the hinge when the device has one panel`() throws {
        let rig = single()

        _ = try rig.display().resolve()

        verify(rig.hinge).angle().called(0)
    }

    @Test func `should bind the panel the hinge has lit when the device has two`() throws {
        let binding = try duo().display().resolve()

        #expect(binding.connectedScreenId == 3)
        #expect(binding.panel == .secondary)
    }

    @Test func `should bind a pinned panel whatever the hinge says`() throws {
        let rig = duo()

        let binding = try rig.display(pinned: .primary).resolve()

        #expect(binding.connectedScreenId == 1)
        verify(rig.hinge).angle().called(0)
    }

    @Test func `should bind CarPlay to the external screen attached beside the phone`() throws {
        let binding = try carPlay().display(.carPlay).resolve()

        #expect(binding.connectedScreenId == 2)
        #expect(binding.size == Size(width: 720, height: 480))
    }

    @Test func `should not bind a plane of a device that is not in the set`() {
        #expect(throws: SimulatorError.notFound(udid: "U")) {
            try Rig(device: nil, enumerate: Self.phone).display().resolve()
        }
    }

    // MARK: - its screen

    @Test func `should stream the plane it binds`() throws {
        let display = single().display()

        let screen = try #require(display.screen() as? SimulatorKitScreen)

        #expect(screen.binding == (try display.resolve()))
    }

    @Test func `should stream the plane it last bound when binding again fails`() throws {
        let device = FakeKit.device([(1206, 2622)]).0
        let host = MockDeviceHost()
        given(host).resolveDevice(udid: .any).willReturn(device)
        let calls = Calls()
        let display = SimulatorKitDisplay(
            kind: .phone, udid: "U", host: host,
            enumerateIO: {
                guard calls.next() == 0 else { throw ObservedScreenError.unavailable }
                return Self.phone
            },
            hinge: MockHinge())
        let bound = try display.resolve()

        let screen = try #require(display.screen() as? SimulatorKitScreen)

        #expect(screen.binding == bound)
    }

    @Test func `should stream no particular plane when it has never bound one`() throws {
        let screen = try #require(Rig(device: nil, enumerate: Self.phone).display().screen() as? SimulatorKitScreen)

        #expect(screen.binding == nil)
    }

    // MARK: - its input

    @Test func `should touch the built-in slot when the device has one panel`() {
        let input = single().display().input()

        #expect((input as? IndigoHIDInput)?.touchTarget == IndigoHIDTouchTarget.phone)
    }

    @Test func `should touch the lit panel's own digitizer and press keys through the guest on a foldable`() throws {
        let input = duo(keys: MockDeviceKeys()).display().input()

        let foldable = try #require(input as? FoldableInput)
        #expect((foldable.touches as? IndigoHIDInput)?.touchTarget == IndigoHIDTouchTarget.panel(screenId: 3))
    }

    @Test func `should touch the lit panel's own digitizer on a foldable with no guest keys`() {
        let input = duo().display().input()

        #expect((input as? IndigoHIDInput)?.touchTarget == IndigoHIDTouchTarget.panel(screenId: 3))
    }

    @Test func `should touch CarPlay through its own service`() {
        let input = carPlay().display(.carPlay).input()

        #expect((input as? IndigoHIDInput)?.touchTarget == IndigoHIDTouchTarget.carPlay)
    }

    @Test func `should touch CarPlay through the probe target the environment names`() {
        var rig = carPlay()
        rig.environment = ["BAGUETTE_CARPLAY_TARGET": "0x12C"]

        let input = rig.display(.carPlay).input()

        #expect((input as? IndigoHIDInput)?.touchTarget == 300)
    }

    // MARK: - observing its screen

    @Test func `should observe the phone panel in points with its rotation`() throws {
        var rig = single()
        rig.orientation = .landscapeLeft

        let screen = try rig.display().observedScreen()

        #expect(screen == AXScreen(
            width: 402, height: 874, orientation: .landscapeLeft,
            target: ScreenTarget(screenId: 1, litPanel: .primary, pixelSize: Size(width: 1206, height: 2622))))
    }

    @Test func `should observe the panel a fresh hinge sample lights on a foldable`() throws {
        let rig = duo()

        let screen = try rig.display().observedScreen()

        #expect(screen.target == ScreenTarget(
            screenId: 3, litPanel: .secondary, pixelSize: Size(width: 2007, height: 2853)))
        verify(rig.guestHinge).angle().called(1)
    }

    @Test func `should observe nothing on CarPlay or a pinned panel`() {
        #expect(throws: ObservedScreenError.unavailable) { try carPlay().display(.carPlay).observedScreen() }
        #expect(throws: ObservedScreenError.unavailable) { try single().display(pinned: .primary).observedScreen() }
    }

    @Test func `should observe nothing on a device that is not in the set`() {
        #expect(throws: ObservedScreenError.unavailable) {
            try Rig(device: nil, enumerate: Self.phone).display().observedScreen()
        }
    }

    // MARK: - rechecking it

    @Test func `should recheck by observing when nothing has been observed yet`() throws {
        let display = single().display()

        #expect(try display.recheckedScreen() == (try display.observedScreen()))
    }

    @Test func `should recheck a single panel from its live screen properties`() throws {
        var rig = single()
        rig.live = AXScreen(width: 874, height: 402, orientation: .landscapeRight)
        let display = rig.display()
        _ = try display.observedScreen()

        #expect(try display.recheckedScreen() == rig.live)
    }

    @Test func `should recheck a foldable by sampling its hinge again`() throws {
        let rig = duo()
        let display = rig.display()
        _ = try display.observedScreen()

        _ = try display.recheckedScreen()

        verify(rig.guestHinge).angle().called(2)
    }

    @Test func `should not recheck a single panel that has left the set`() throws {
        let device = FakeKit.device([(1206, 2622)]).0
        let host = MockDeviceHost()
        let calls = Calls()
        given(host).resolveDevice(udid: .any).willProduce { _ in calls.next() < 2 ? device : nil }
        let display = SimulatorKitDisplay(
            kind: .phone, udid: "U", host: host, enumerateIO: { Self.phone }, hinge: MockHinge(),
            readOrientation: { _, _ in .portrait })
        _ = try display.observedScreen()

        #expect(throws: ObservedScreenError.unavailable) { try display.recheckedScreen() }
    }

    // MARK: - input pinned to an observation

    @Test func `should pin input to the observed panel while it still matches`() throws {
        var rig = single()
        let observed = try rig.display().observedScreen()
        rig.live = observed

        let pinned = try rig.display().input(expected: try expected(observed))

        #expect((pinned.input as? IndigoHIDInput)?.touchTarget == IndigoHIDTouchTarget.phone)
        #expect(pinned.screenGuard.allows(.down))
    }

    @Test func `should hold input back once the single panel no longer matches`() throws {
        let rig = single()
        let observed = try rig.display().observedScreen()

        let pinned = try rig.display().input(expected: try expected(observed))

        #expect(!pinned.screenGuard.allows(.move))
    }

    @Test func `should pin a foldable's input to the lit panel and its keys to the guest`() throws {
        let rig = duo(keys: MockDeviceKeys())
        let observed = try rig.display().observedScreen()

        let pinned = try rig.display().input(expected: try expected(observed))

        let foldable = try #require(pinned.input as? FoldableInput)
        #expect((foldable.touches as? IndigoHIDInput)?.touchTarget == IndigoHIDTouchTarget.panel(screenId: 3))
        #expect(pinned.screenGuard.allows(.down))
    }

    @Test func `should pin a foldable's touches to the lit panel when it has no guest keys`() throws {
        let rig = duo()
        let observed = try rig.display().observedScreen()

        let pinned = try rig.display().input(expected: try expected(observed))

        #expect((pinned.input as? IndigoHIDInput)?.touchTarget == IndigoHIDTouchTarget.panel(screenId: 3))
    }

    @Test func `should refuse input when the screen has changed since it was observed`() throws {
        var rig = single()
        let observed = try rig.display().observedScreen()
        rig.orientation = .landscapeLeft

        #expect(throws: ExpectedScreen.Failure.changed) {
            try rig.display().input(expected: try expected(observed))
        }
    }

    @Test func `should hold input back once a single panel has left the set`() throws {
        let device = FakeKit.device([(1206, 2622)]).0
        let host = MockDeviceHost()
        let calls = Calls()
        given(host).resolveDevice(udid: .any).willProduce { _ in calls.next() < 2 ? device : nil }
        let display = SimulatorKitDisplay(
            kind: .phone, udid: "U", host: host, enumerateIO: { Self.phone }, hinge: MockHinge(),
            readOrientation: { _, _ in .portrait })
        let observed = try single().display().observedScreen()

        let pinned = try display.input(expected: try expected(observed))

        #expect(!pinned.screenGuard.allows(.down))
    }
}

/// Counts calls across closures that must be `Sendable`.
private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { defer { count += 1 }; return count } }
}
