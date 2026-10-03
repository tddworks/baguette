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

    @Test func `AX observations reject changed orientation size or panel`() throws {
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

    @Test func `an unobservable display fails the query instead of guessing a screen`() throws {
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

    @Test func `a changed display tells the caller to observe again`() {
        #expect(
            AXPTranslatorAccessibility.Failure.displayChanged.localizedDescription
                == "The display changed while reading accessibility; discard the result and observe again.")
    }

    @Test func `describeAll returns nil when host has no matching device`() throws {
        let host = MockDeviceHost()
        given(host).resolveDevice(udid: .any).willReturn(nil)
        let ax = AXPTranslatorAccessibility(udid: "ghost", host: host) {
            throw ObservedScreenError.unavailable
        }

        #expect(try ax.describeAll() == nil)
    }

    @Test func `describeAt returns nil when host has no matching device`() throws {
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

    @Test func `a failed guest frontmost query propagates after the geometry was read`() throws {
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

    @Test func `the application lookup returns the translation the device answers with`() throws {
        let translation = NSObject()
        let device = AnsweringDevice(answer: TranslationResponse(translation))
        let dispatcher = TokenDispatcher()

        let answered = try dispatcher.application(
            pid: 42, on: device, udid: "ghost", timeout: 1, request: { _ in NSObject() })

        #expect(answered === translation)
        #expect(device.requests == 1)
    }

    @Test func `a device without a translation and a missing request class fail by name`() {
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
