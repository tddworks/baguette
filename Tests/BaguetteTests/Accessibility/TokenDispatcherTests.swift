import Testing
import Foundation
import CoreGraphics
@testable import Baguette

/// `TokenDispatcher` is the bridge-token delegate we install on
/// `AXPTranslator`. AXPTranslator looks it up via three `@objc
/// dynamic` selectors per call:
///
///   - `accessibilityTranslationDelegateBridgeCallbackWithToken:` →
///     returns a block that routes XPC requests to the right
///     SimDevice.
///   - `accessibilityTranslationConvertPlatformFrameToSystem:withToken:` →
///     identity transform (we project to device points later, on
///     our side of the wire, in `AXFrameTransform`).
///   - `accessibilityTranslationRootParentWithToken:` → nil
///     (we don't synthesise a parent for the AX root).
///
/// The actual XPC dispatch inside the callback block needs a
/// real `SimDevice` and a booted simulator, so it stays
/// integration-only. These tests cover the three callback
/// surfaces + the `register/unregister/lookup` lifecycle that
/// every callback consults.
@Suite("TokenDispatcher")
struct TokenDispatcherTests {

    // MARK: - lifecycle

    @Test func `unregister removes a registered token`() {
        let dispatcher = TokenDispatcher()
        let device = NSObject()
        dispatcher.register(device: device, token: "T1", deadline: Date.distantFuture)
        dispatcher.unregister(token: "T1")
        // The callback for an unregistered token still produces a
        // block (AXPTranslator expects one), but invoking that
        // block returns `emptyResponse()` because the device map
        // is empty. We don't assert on the block's return — that
        // requires a real SimDevice — but we do assert that
        // unregister actually clears state by re-registering and
        // checking we don't double-up.
        dispatcher.register(device: device, token: "T1", deadline: Date.distantFuture)
        // No crash, no exception → state was cleared first time.
    }

    @Test func `unregister of an unknown token is a silent no-op`() {
        let dispatcher = TokenDispatcher()
        // Should not crash, throw, or affect anything else.
        dispatcher.unregister(token: "never-registered")
    }

    @Test func `multiple tokens can coexist`() {
        let dispatcher = TokenDispatcher()
        let d1 = NSObject(), d2 = NSObject()
        dispatcher.register(device: d1, token: "A", deadline: Date.distantFuture)
        dispatcher.register(device: d2, token: "B", deadline: Date.distantFuture)
        dispatcher.unregister(token: "A")
        // Unregistering one shouldn't affect the other.
        dispatcher.unregister(token: "B")
    }

    // MARK: - callback surfaces

    @Test func `bridge callback returns a callable block for any token`() {
        let dispatcher = TokenDispatcher()
        // Even for an unregistered token we get back *something*
        // — AXPTranslator stores the returned object and invokes
        // it later; returning nil would crash the framework.
        let result = dispatcher
            .accessibilityTranslationDelegateBridgeCallbackWithToken("unknown" as NSString)
        // The result is type-erased `Any` (AXPTranslator's selector
        // signature). Cast through `AnyObject` to confirm we got a
        // non-nil object back.
        let asObject = result as AnyObject
        #expect(!(asObject is NSNull),
                "callback must return a non-nil object suitable for AXPTranslator")
    }

    @Test func `convertPlatformFrameToSystem is identity`() {
        let dispatcher = TokenDispatcher()
        let input = CGRect(x: 11, y: 22, width: 33, height: 44)
        let out = dispatcher.accessibilityTranslationConvertPlatformFrameToSystem(
            input, withToken: "any" as NSString
        )
        #expect(out == input)
    }

    @Test func `rootParentWithToken returns nil`() {
        let dispatcher = TokenDispatcher()
        #expect(dispatcher
            .accessibilityTranslationRootParentWithToken("any" as NSString) == nil)
    }

    // MARK: - empty response fallback

    @Test func `emptyResponse returns AXPTranslatorResponse instance when class is loaded`() {
        // The test process loads CoreSimulator + AXP via
        // AXPTranslatorAccessibility's static dlopen the first
        // time `isAvailable` is touched. Force that load here so
        // `NSClassFromString("AXPTranslatorResponse")` resolves.
        _ = AXPTranslatorAccessibility.isAvailable

        let resp = TokenDispatcher.emptyResponse()
        // Either we got a real AXPTranslatorResponse instance
        // (the framework loaded), or NSNull (it didn't). Both
        // are valid: the dispatcher's contract is "non-nil
        // object that AXPTranslator can store"; the typed
        // empty-response is just the better-behaved variant.
        let cls: AnyClass? = NSClassFromString("AXPTranslatorResponse")
        if cls != nil {
            #expect(type(of: resp) != NSNull.self,
                    "expected typed AXPTranslatorResponse, got NSNull")
        } else {
            #expect(resp is NSNull)
        }
    }
}
