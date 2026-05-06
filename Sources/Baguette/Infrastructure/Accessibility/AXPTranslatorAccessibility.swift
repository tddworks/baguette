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
    private weak var host: CoreSimulators?

    /// Cap on tree-walk recursion depth. Real iOS screens rarely
    /// exceed 20–30 levels; the cap prevents pathological cycles.
    private static let maxDepth = 60

    /// Per-XPC-call timeout in seconds. The dispatcher's block waits
    /// synchronously on each request; keeping this short means a
    /// hung simulator doesn't pin our caller.
    private static let xpcTimeoutSeconds: Double = 5.0

    init(udid: String, host: CoreSimulators) {
        self.udid = udid
        self.host = host
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
        guard let device = host?.resolveDevice(udid: udid) else {
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

        let pointSize = Self.devicePointSize(for: device)
        let rootFrame = Self.frame(of: rootElement)
        let context = WalkContext(
            token: token,
            deadline: deadline,
            rootFrame: rootFrame,
            pointSize: pointSize
        )
        return walk(element: rootElement, depth: 0, context: context)
    }

    // MARK: - element → AXNode

    private struct WalkContext {
        let token: String
        let deadline: Date
        let rootFrame: CGRect
        let pointSize: CGSize
    }

    private func walk(element: NSObject, depth: Int, context: WalkContext) -> AXNode {
        let role  = Self.stringValue(element, "accessibilityRole") ?? "AXUnknown"
        let macFrame = Self.frame(of: element)
        let frame = transform(macFrame, in: context)

        let kids: [AXNode] = depth >= Self.maxDepth || Date() >= context.deadline
            ? []
            : (childObjects(of: element, token: context.token).map {
                walk(element: $0, depth: depth + 1, context: context)
            })

        return AXNode(
            role: role,
            subrole:    Self.stringValue(element, "accessibilitySubrole"),
            label:      Self.stringValue(element, "accessibilityLabel"),
            value:      Self.stringValueOrNumber(element, "accessibilityValue"),
            identifier: Self.stringValue(element, "accessibilityIdentifier"),
            title:      Self.stringValue(element, "accessibilityTitle"),
            help:       Self.stringValue(element, "accessibilityHelp"),
            frame: Rect(
                origin: Point(x: Double(frame.origin.x), y: Double(frame.origin.y)),
                size: Size(width: Double(frame.size.width), height: Double(frame.size.height))
            ),
            enabled: Self.boolValue(element, "accessibilityEnabled", default: true)
                  || Self.boolValue(element, "isAccessibilityEnabled", default: false),
            focused: Self.boolValue(element, "isAccessibilityFocused", default: false)
                  || Self.boolValue(element, "accessibilityFocused", default: false),
            hidden:  Self.boolValue(element, "isAccessibilityHidden", default: false)
                  || Self.boolValue(element, "accessibilityHidden", default: false),
            children: kids
        )
    }

    private func childObjects(of element: NSObject, token: String) -> [NSObject] {
        let kids = (element.value(forKey: "accessibilityChildren") as? [NSObject]) ?? []
        for kid in kids {
            Self.stampElementTranslation(token: token, on: kid)
        }
        return kids
    }

    /// Project `mac` (host-window coords reported by AXPTranslator)
    /// into device points, using the simulator's known logical
    /// `pointSize` and the AX root's reported `rootFrame`. Uses
    /// width-uniform scale + vertical centering — same projection
    /// AXe / Silbercue use, which matches what Simulator.app
    /// internally does for letterboxed device aspect ratios.
    private func transform(_ mac: CGRect, in ctx: WalkContext) -> CGRect {
        guard ctx.rootFrame.width > 0,
              ctx.rootFrame.height > 0,
              ctx.pointSize.width > 0,
              ctx.pointSize.height > 0
        else { return mac }
        let scale = ctx.pointSize.width / ctx.rootFrame.width
        let yOffset = (ctx.pointSize.height - ctx.rootFrame.height * scale) / 2
        return CGRect(
            x: (mac.origin.x - ctx.rootFrame.origin.x) * scale,
            y: (mac.origin.y - ctx.rootFrame.origin.y) * scale + yOffset,
            width: mac.size.width * scale,
            height: mac.size.height * scale
        )
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

    private static func frame(of element: NSObject) -> CGRect {
        let sel = NSSelectorFromString("accessibilityFrame")
        guard element.responds(to: sel),
              let imp = class_getMethodImplementation(type(of: element), sel) else {
            return .zero
        }
        typealias Fn = @convention(c) (AnyObject, Selector) -> CGRect
        return unsafeBitCast(imp, to: Fn.self)(element, sel)
    }

    private static func stringValue(_ obj: NSObject, _ key: String) -> String? {
        guard let raw = obj.value(forKey: key) as? String, !raw.isEmpty else { return nil }
        return raw
    }

    /// Some `accessibilityValue` properties return NSNumber (sliders,
    /// progress views) — coerce to a stringified value so the JSON
    /// stays a plain string column.
    private static func stringValueOrNumber(_ obj: NSObject, _ key: String) -> String? {
        let raw = obj.value(forKey: key)
        if let s = raw as? String { return s.isEmpty ? nil : s }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }

    private static func boolValue(_ obj: NSObject, _ key: String, default fallback: Bool) -> Bool {
        if let n = obj.value(forKey: key) as? NSNumber { return n.boolValue }
        return fallback
    }

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
    private static func devicePointSize(for device: NSObject) -> CGSize {
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
    fileprivate static func emptyResponse() -> AnyObject {
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
