import Foundation
import ObjectiveC
import CoreGraphics

/// Production `Accessibility` — backed by `AXPTranslator` from the
/// private `AccessibilityPlatformTranslation` framework.
///
/// The non-trivial part is *bridge wiring*: out-of-Simulator.app,
/// `AXPTranslator` won't talk to the in-simulator AX service unless
/// we install a `bridgeTokenDelegate` that knows how to route an
/// `AXPTranslatorRequest` to the right `SimDevice`'s
/// `-sendAccessibilityRequestAsync:` XPC channel. Without that
/// delegate, every `frontmostApplication…` call returns nil.
///
/// Recipe (per call):
///
///   1. Generate a fresh UUID token; register it → SimDevice in the
///      shared dispatcher.
///   2. Call `-frontmostApplicationWithDisplayId:bridgeDelegateToken:`.
///      The translator stores the token internally and, on every XPC
///      request, asks the dispatcher "what device for this token?".
///   3. Set the same token as `bridgeDelegateToken` on the returned
///      translation object — children inherit it, but the translator
///      re-reads it for every sub-request, so missing this means
///      child element reads silently fail.
///   4. Convert translation → `AXPMacPlatformElement` and walk
///      `accessibilityChildren`, propagating the token onto every
///      sub-translation.
///   5. Unregister on exit.
///
/// Coordinates: AXP frames come back in **macOS host-window**
/// coordinates. We project to device points using the simulator's
/// `mainScreenSize` / `mainScreenScale` so callers can pipe values
/// straight back into baguette's gesture wire (which is also in
/// device points).
///
/// Cribbed from cameroncooke/AXe + Silbercue/SilbercueSwift's
/// `AXPBridge.swift` — the only Swift implementations of the iOS-26
/// out-of-Simulator.app dispatcher pattern that we know of.
final class AXPTranslatorAccessibility: Accessibility, @unchecked Sendable {
    private let udid: String
    private let host: any DeviceHost

    /// Cap on tree-walk recursion depth. Real iOS screens rarely
    /// exceed 20–30 levels; the cap prevents pathological cycles.
    private static let maxDepth = 60

    /// Per-XPC-call timeout in seconds. The dispatcher's block waits
    /// synchronously on each request; keeping this short means a
    /// hung simulator doesn't pin our caller.
    private static let xpcTimeoutSeconds: Double = 5.0

    init(udid: String, host: any DeviceHost) {
        self.udid = udid
        self.host = host
    }

    private func resolveDevice() -> NSObject? {
        host.resolveDevice(udid: udid)
    }

    // MARK: - Accessibility

    func describeAll() throws -> AXNode? {
        try fetchTree(hitTest: nil)
    }

    func describeAt(point: Point) throws -> AXNode? {
        // No native hit-test that survives the dispatcher pattern
        // reliably — AXP's `objectAtPoint:` returns a translation
        // whose `bridgeDelegateToken` we'd have to seed before the
        // call (chicken / egg). Instead, fetch the tree once and
        // hit-test locally with our `AXNode.hitTest`. Cheap
        // post-fetch, and reuses the value-type semantics we
        // already TDD'd.
        guard let tree = try fetchTree(hitTest: point) else { return nil }
        return tree.hitTest(point) ?? tree
    }

    // MARK: - tree fetch

    private func fetchTree(hitTest: Point?) throws -> AXNode? {
        guard Self.isAvailable else {
            logErr("[ax] framework / dispatcher not available")
            return nil
        }
        guard let device = resolveDevice() else {
            logErr("[ax] device not found: \(udid)")
            return nil
        }

        let token = UUID().uuidString
        let deadline = Date().addingTimeInterval(Self.xpcTimeoutSeconds)
        Self.sharedDispatcher.register(device: device, token: token, deadline: deadline)
        defer { Self.sharedDispatcher.unregister(token: token) }

        guard let translator = Self.sharedTranslator else { return nil }

        guard let translation = Self.frontmostApplication(
            translator: translator, token: token
        ) else {
            log("[ax] no frontmost application for udid=\(udid)")
            return nil
        }
        Self.stamp(token: token, on: translation)

        guard let rootElement = Self.macPlatformElement(
            translator: translator, translation: translation
        ) else {
            log("[ax] no mac platform element from translation")
            return nil
        }
        Self.stampElementTranslation(token: token, on: rootElement)
        Self.stampSubtree(rootElement, token: token, depthCap: Self.maxDepth)

        let pointSize = Self.devicePointSize(for: device)
        let rootFrame = AXElementReader.frame(of: rootElement)
        return AXNode.walk(
            from: rootElement,
            transform: AXFrameTransform(rootFrame: rootFrame, pointSize: pointSize),
            depthCap: Self.maxDepth,
            deadline: deadline
        )
    }

    /// Stamp every reachable child translation with `token` so
    /// AXPTranslator's per-sub-XPC `bridgeDelegateToken` lookups
    /// resolve to our dispatcher entry. The walk that builds
    /// `AXNode`s is pure logic in Domain; this side-effecting
    /// pre-walk has to live in the adapter because it's part of
    /// the AXPTranslator handshake.
    private static func stampSubtree(
        _ element: NSObject, token: String, depthCap: Int, depth: Int = 0
    ) {
        guard depth < depthCap else { return }
        let kids = AXElementReader.children(of: element)
        for kid in kids {
            stampElementTranslation(token: token, on: kid)
            stampSubtree(kid, token: token, depthCap: depthCap, depth: depth + 1)
        }
    }

    // MARK: - shared framework + dispatcher (process-wide)

    /// `true` once dlopen has succeeded, `+sharedInstance` resolved,
    /// and `bridgeTokenDelegate` installed. Computed once and
    /// cached as a side-effect of the static let initializers.
    static var isAvailable: Bool {
        sharedTranslator != nil
    }

    nonisolated(unsafe) private static let frameworksLoaded: Bool = {
        let path = "/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation"
        if dlopen(path, RTLD_NOW | RTLD_GLOBAL) == nil {
            logErr("[ax] AccessibilityPlatformTranslation dlopen failed: \(dlerrorString())")
            return false
        }
        return true
    }()

    nonisolated(unsafe) private static let sharedTranslator: NSObject? = {
        guard frameworksLoaded else { return nil }
        guard let cls = NSClassFromString("AXPTranslator") else {
            logErr("[ax] AXPTranslator class not found")
            return nil
        }
        let sel = NSSelectorFromString("sharedInstance")
        guard let metaCls = object_getClass(cls),
              let imp = class_getMethodImplementation(metaCls, sel) else {
            logErr("[ax] +sharedInstance not found")
            return nil
        }
        typealias Fn = @convention(c) (AnyClass, Selector) -> AnyObject?
        guard let inst = unsafeBitCast(imp, to: Fn.self)(cls, sel) as? NSObject else {
            logErr("[ax] +sharedInstance returned nil")
            return nil
        }
        // Critical: install the token delegate so the translator can
        // route XPC requests to the right SimDevice. Without this
        // step every frontmost-app call returns nil.
        inst.setValue(sharedDispatcher, forKey: "bridgeTokenDelegate")
        log("[ax] AXPTranslator wired with bridgeTokenDelegate")
        return inst
    }()

    nonisolated(unsafe) static let sharedDispatcher = TokenDispatcher()

    // MARK: - AXPTranslator entry points

    private static func frontmostApplication(
        translator: NSObject, token: String
    ) -> NSObject? {
        let sel = NSSelectorFromString("frontmostApplicationWithDisplayId:bridgeDelegateToken:")
        guard translator.responds(to: sel),
              let imp = class_getMethodImplementation(type(of: translator), sel) else {
            logErr("[ax] -frontmostApplicationWithDisplayId:bridgeDelegateToken: not found")
            return nil
        }
        typealias Fn = @convention(c) (AnyObject, Selector, UInt32, AnyObject) -> AnyObject?
        return unsafeBitCast(imp, to: Fn.self)(translator, sel, 0, token as NSString) as? NSObject
    }

    private static func macPlatformElement(
        translator: NSObject, translation: NSObject
    ) -> NSObject? {
        let sel = NSSelectorFromString("macPlatformElementFromTranslation:")
        guard translator.responds(to: sel),
              let imp = class_getMethodImplementation(type(of: translator), sel) else {
            logErr("[ax] -macPlatformElementFromTranslation: not found")
            return nil
        }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject?
        return unsafeBitCast(imp, to: Fn.self)(translator, sel, translation) as? NSObject
    }

    // MARK: - element accessors

    // The element-reading helpers (string / bool / frame /
    // children) used to live here; they've been promoted to
    // Domain/Accessibility/AXElementReader.swift so the
    // AXNode.walk(...) pure factory can reuse them. The adapter
    // now keeps only the pieces that genuinely require the
    // AXPTranslator handshake (token stamping, dispatcher,
    // dlopen).

    /// Stamp a token onto an `AXPTranslationObject` (the inner
    /// translation, NOT the outer macPlatformElement). The
    /// translator re-reads this for every XPC request that touches
    /// this object.
    private static func stamp(token: String, on translation: NSObject) {
        translation.setValue(token, forKey: "bridgeDelegateToken")
    }

    /// Stamp a token onto an `AXPMacPlatformElement`'s underlying
    /// translation. Children inherit a `translation` sub-property,
    /// so we recurse to it.
    private static func stampElementTranslation(token: String, on element: NSObject) {
        if let trans = element.value(forKey: "translation") as? NSObject {
            stamp(token: token, on: trans)
        }
    }

    // MARK: - device → screen size

    /// Resolve the simulator's logical-point size from its
    /// `deviceType.mainScreenSize` (pixels) / `mainScreenScale`.
    /// Falls back to a sensible iPhone-15-Pro size when the
    /// runtime doesn't expose the values (unlikely on iOS 26).
    /// Internal so unit tests can drive it against a fake device.
    static func devicePointSize(for device: NSObject) -> CGSize {
        let fallback = CGSize(width: 393, height: 852)
        guard let deviceType = device.value(forKey: "deviceType") as? NSObject else {
            return fallback
        }
        let pixelSize: CGSize
        if let raw = deviceType.value(forKey: "mainScreenSize") as? CGSize {
            pixelSize = raw
        } else if let nsv = deviceType.value(forKey: "mainScreenSize") as? NSValue {
            pixelSize = nsv.sizeValue
        } else {
            return fallback
        }
        let scale = (deviceType.value(forKey: "mainScreenScale") as? NSNumber)?.doubleValue ?? 3.0
        guard scale > 0 else { return fallback }
        return CGSize(
            width: pixelSize.width / scale,
            height: pixelSize.height / scale
        )
    }
}

// MARK: - TokenDispatcher

/// Bridge-token delegate installed on `AXPTranslator`. The
/// translator calls `accessibilityTranslationDelegateBridgeCallbackWithToken:`
/// with each token, and we hand back a block that knows how to
/// route an `AXPTranslatorRequest` over the `SimDevice` XPC
/// channel registered for that token.
///
/// `@objc dynamic` and `NSObject` subclass are required: AXP
/// invokes us via ObjC dispatch, which means non-`@objc` Swift
/// methods are invisible.
final class TokenDispatcher: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var deviceForToken: [String: NSObject] = [:]
    private var deadlineForToken: [String: Date] = [:]

    func register(device: NSObject, token: String, deadline: Date) {
        lock.lock(); defer { lock.unlock() }
        deviceForToken[token] = device
        deadlineForToken[token] = deadline
    }

    func unregister(token: String) {
        lock.lock(); defer { lock.unlock() }
        deviceForToken.removeValue(forKey: token)
        deadlineForToken.removeValue(forKey: token)
    }

    private func lookup(token: String) -> (NSObject, Date)? {
        lock.lock(); defer { lock.unlock() }
        guard let dev = deviceForToken[token] else { return nil }
        return (dev, deadlineForToken[token] ?? Date.distantFuture)
    }

    @objc dynamic func accessibilityTranslationDelegateBridgeCallbackWithToken(
        _ token: NSString
    ) -> Any {
        let key = token as String
        let entry = self.lookup(token: key)
        let block: @convention(block) (AnyObject) -> AnyObject = { [weak self] request in
            guard let self else { return TokenDispatcher.emptyResponse() }
            guard let (device, deadline) = entry else {
                return TokenDispatcher.emptyResponse()
            }
            let remaining = max(0, deadline.timeIntervalSinceNow)
            if remaining <= 0 { return TokenDispatcher.emptyResponse() }
            let timeout = min(remaining, 10.0)
            return self.sendAccessibilityRequest(
                request, to: device, timeout: timeout
            ) ?? TokenDispatcher.emptyResponse()
        }
        return block
    }

    @objc dynamic func accessibilityTranslationConvertPlatformFrameToSystem(
        _ rect: CGRect, withToken token: NSString
    ) -> CGRect {
        rect
    }

    @objc dynamic func accessibilityTranslationRootParentWithToken(
        _ token: NSString
    ) -> AnyObject? {
        nil
    }

    /// Synchronous wrapper around `SimDevice.sendAccessibilityRequestAsync:`.
    /// Waits up to `timeout` seconds for the XPC reply.
    private func sendAccessibilityRequest(
        _ request: AnyObject, to device: NSObject, timeout: Double
    ) -> AnyObject? {
        let sel = NSSelectorFromString("sendAccessibilityRequestAsync:completionQueue:completionHandler:")
        guard let imp = class_getMethodImplementation(type(of: device), sel) else {
            logErr("[ax] SimDevice.sendAccessibilityRequestAsync not found")
            return nil
        }
        typealias Fn = @convention(c) (
            AnyObject, Selector, AnyObject, DispatchQueue, Any
        ) -> Void
        let send = unsafeBitCast(imp, to: Fn.self)

        let group = DispatchGroup()
        group.enter()
        let queue = DispatchQueue(label: "baguette.ax.xpc")
        // Use a Sendable box so the completion-block capture compiles
        // under strict concurrency without copying through `inout`.
        final class Box: @unchecked Sendable { var value: AnyObject? }
        let box = Box()
        let completion: @convention(block) (AnyObject?) -> Void = { response in
            box.value = response
            group.leave()
        }
        send(device, sel, request, queue, completion as Any)
        if group.wait(timeout: .now() + timeout) == .timedOut {
            logErr("[ax] XPC request timed out after \(timeout)s")
            return nil
        }
        return box.value
    }

    /// Fallback empty response. AXPTranslator will re-issue if the
    /// response is `NSNull` rather than an `AXPTranslatorResponse`,
    /// so prefer the framework's typed empty when available.
    /// Fallback response handed back when AXPTranslator invokes
    /// our dispatcher's callback block with no registered device
    /// for the token (or the XPC round-trip times out / errors).
    /// Internal so unit tests can drive it directly without
    /// installing the dispatcher onto a real translator.
    static func emptyResponse() -> AnyObject {
        if let cls = NSClassFromString("AXPTranslatorResponse") {
            let sel = NSSelectorFromString("emptyResponse")
            if let metaCls = object_getClass(cls),
               let imp = class_getMethodImplementation(metaCls, sel) {
                typealias Fn = @convention(c) (AnyClass, Selector) -> AnyObject?
                if let resp = unsafeBitCast(imp, to: Fn.self)(cls, sel) {
                    return resp
                }
            }
        }
        return NSNull()
    }
}
