import Testing
import Foundation
import Mockable
@testable import Baguette

/// Unit tests for `AXPTranslatorAccessibility`'s host-resolution
/// branches — the only paths we can exercise without a live
/// AXPTranslator + bridge-token-delegate handshake.
///
/// The actual XPC round-trip into the simulator's accessibility
/// service depends on private framework load + dispatcher install
/// + `frontmostApplicationWithDisplayId:` returning a usable
/// translation. That path is integration-only — manually
/// smoke-tested via `baguette describe-ui` against a booted sim.
@Suite("AXPTranslatorAccessibility — error paths")
struct AXPTranslatorAccessibilityErrorTests {

    @Test func `should reject a reading when orientation, size or panel changed during it`() throws {
        let before = AXScreen(
            width: 402, height: 874, orientation: .portrait,
            target: ScreenTarget(screenId: 1, litPanel: nil, pixelSize: Size(width: 1206, height: 2622)))
        try AXPTranslatorAccessibility.requireUnchanged(before, before)
        let changed: [AXPTranslatorAccessibility.DisplayGeometry] = [
            AXScreen(width: 402, height: 874, orientation: .landscapeLeft, target: before.target),
            AXScreen(width: 744, height: 1133, orientation: .portrait, target: before.target),
            AXScreen(
                width: 402, height: 874, orientation: .portrait,
                target: ScreenTarget(screenId: 2, litPanel: nil, pixelSize: Size(width: 1206, height: 2622))),
        ]
        for after in changed {
            #expect(throws: AXPTranslatorAccessibility.Failure.displayChanged) {
                try AXPTranslatorAccessibility.requireUnchanged(before, after)
            }
        }
    }

    @Test func `should fail the query rather than guess a screen when the display cannot be observed`() throws {
        let host = MockDeviceHost()
        given(host).resolveDevice(udid: .any).willReturn(NSObject())
        let ax = AXPTranslatorAccessibility(udid: "ghost", host: host) {
            throw ObservedScreenError.unavailable
        }

        // The geometry is read before any AXP work: a device that is present
        // but cannot name its screen is an error, not an empty tree.
        #expect(throws: ObservedScreenError.unavailable) { try ax.describeAll() }
        #expect(throws: ObservedScreenError.unavailable) { try ax.describeAt(point: Point(x: 10, y: 20)) }
    }

    @Test func `should tell the caller to observe again when the display changed`() {
        #expect(
            AXPTranslatorAccessibility.Failure.displayChanged.localizedDescription
                == "The display changed while reading accessibility; discard the result and observe again.")
    }

    @Test func `should describe no UI when no device matches the udid`() throws {
        let host = MockDeviceHost()
        given(host).resolveDevice(udid: .any).willReturn(nil)
        let ax = AXPTranslatorAccessibility(udid: "ghost", host: host) {
            throw ObservedScreenError.unavailable
        }

        #expect(try ax.describeAll() == nil)
    }

    @Test func `should describe no element at a point when no device matches the udid`() throws {
        let host = MockDeviceHost()
        given(host).resolveDevice(udid: .any).willReturn(nil)
        let ax = AXPTranslatorAccessibility(udid: "ghost", host: host) {
            throw ObservedScreenError.unavailable
        }

        #expect(try ax.describeAt(point: Point(x: 10, y: 20)) == nil)
    }
}

@Suite("AXPTranslatorAccessibility — frontmost lookup")
struct AXPTranslatorFrontmostTests {
    private static let screen = AXScreen(
        width: 402, height: 874, orientation: .portrait,
        target: ScreenTarget(screenId: 1, litPanel: nil, pixelSize: Size(width: 1206, height: 2622)))

    @Test func `should surface the failure when the frontmost app query fails on the guest`() throws {
        struct GuestDown: Error, Equatable {}
        let host = MockDeviceHost()
        given(host).resolveDevice(udid: .any).willReturn(NSObject())
        let ax = AXPTranslatorAccessibility(
            udid: "ghost", host: host, deviceSetPath: "/custom set",
            frontmostPID: { udid, deviceSet in
                #expect(udid == "ghost")
                #expect(deviceSet == "/custom set")
                throw GuestDown()
            }
        ) { Self.screen }

        #expect(throws: GuestDown()) { try ax.describeAll() }
    }

    @Test func `should read a screen it has already observed without observing it in full again`() throws {
        struct LiveReadFailed: Error, Equatable {}
        let host = MockDeviceHost()
        given(host).resolveDevice(udid: .any).willReturn(NSObject())
        let ax = AXPTranslatorAccessibility(
            udid: "ghost", host: host,
            recheckGeometry: { throw LiveReadFailed() }
        ) { Self.screen }

        #expect(throws: LiveReadFailed()) { try ax.describeAll() }
    }

    @Test func `should look up the app with the answer the device gives`() throws {
        let translation = NSObject()
        let device = AnsweringDevice(answer: TranslationResponse(translation))
        let dispatcher = TokenDispatcher()

        let answered = try dispatcher.application(
            pid: 42, on: device, udid: "ghost", timeout: 1, request: { _ in NSObject() })

        #expect(answered === translation)
        #expect(device.requests == 1)
    }

    @Test func `should name the device and process when the app lookup gets no answer`() {
        let dispatcher = TokenDispatcher()
        for (device, request, cause) in [
            (AnsweringDevice(answer: nil), { (_: Int32) -> NSObject? in NSObject() }, "returned no application translation"),
            (AnsweringDevice(answer: TranslationResponse(nil)), { _ in NSObject() }, "returned no application translation"),
            (AnsweringDevice(answer: nil), { _ in nil }, "AXPTranslatorRequest is unavailable"),
        ] {
            do {
                _ = try dispatcher.application(pid: 42, on: device, udid: "ghost", timeout: 1, request: request)
                Issue.record("the lookup must fail")
            } catch {
                #expect(error.localizedDescription.contains("ghost"))
                #expect(error.localizedDescription.contains("42"))
                #expect(error.localizedDescription.contains(cause))
            }
        }
    }
}

/// Stands in for a `SimDevice`: answers every accessibility request with
/// one canned response on the caller's completion queue.
private final class AnsweringDevice: NSObject, @unchecked Sendable {
    private let answer: AnyObject?
    private(set) var requests = 0

    init(answer: AnyObject?) { self.answer = answer }

    @objc func sendAccessibilityRequestAsync(
        _ request: AnyObject, completionQueue: DispatchQueue, completionHandler: @escaping (AnyObject?) -> Void
    ) {
        requests += 1
        completionQueue.async { [answer] in completionHandler(answer) }
    }
}

private final class TranslationResponse: NSObject {
    @objc let translationResponse: NSObject?
    init(_ translation: NSObject?) { self.translationResponse = translation }
}
