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
        // Prefer the server-side hit-test. `AXPTranslator` exposes
        // `objectAtPoint:displayId:bridgeDelegateToken:` — the
        // 3-arg form, distinct from the chicken/egg-prone `objectAtPoint:`
        // — which accepts the token as a parameter and therefore
        // plays nicely with the dispatcher pattern. The big win
        // is that it returns elements the static tree walk
        // *misses*: SwiftUI tab bars / nav bars / toolbars
        // routinely enumerate as childless via `describeAll`, but
        // `objectAtPoint` hits the underlying buttons just fine.
        // Discovered while reading Meta's idb
        // (`FBSimulatorAccessibilityCommands.m`:885), where the same
        // selector backs idb's describe-point CLI.
        //
        // Fall back to the original client-side path when the
        // selector isn't available (very old AXPTranslator, hypothetical)
        // or the host-side resolution fails before we get a translator.
        if Self.supportsServerSideHitTest,
           let hit = try hitTestServerSide(point: point) {
            return hit
        }
        guard let tree = try fetchTree(hitTest: point) else { return nil }
        return tree.hitTest(point) ?? tree
    }

    // MARK: - tree fetch

    /// The pieces every AXP entry point needs: a working translator,
    /// a registered token, the frontmost app's root element (which
    /// carries the host-window frame), an `AXFrameTransform` for
    /// projecting/unprojecting coordinates, and the per-call deadline.
    /// Held together inside the closure passed to
    /// `withAXPContext(_:)`, which owns the dispatcher register +
    /// unregister around it.
    private struct AXPContext {
        let translator: NSObject
        let token: String
        let frontmostRoot: NSObject
        let transform: AXFrameTransform
        let deadline: Date
    }

    /// Run `body` inside a fully-prepared AXP context. Handles the
    /// dispatcher token lifecycle (register on entry, unregister on
    /// exit), translator + frontmost-app resolution, and the
    /// host-coord ↔ device-point `AXFrameTransform` setup. Returns
    /// `nil` if any setup step fails (framework not loaded, device
    /// missing, frontmost app not resolvable, etc.) — same nil
    /// semantics each entry point had pre-refactor.
    private func withAXPContext<T>(
        _ body: (AXPContext) throws -> T?
    ) throws -> T? {
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

        guard let frontmostRoot = Self.macPlatformElement(
            translator: translator, translation: translation
        ) else {
            log("[ax] no mac platform element from translation")
            return nil
        }
        let pointSize = Self.devicePointSize(for: device)
        let rootFrame = AXElementReader.frame(of: frontmostRoot)
        let transform = AXFrameTransform(rootFrame: rootFrame, pointSize: pointSize)

        return try body(AXPContext(
            translator: translator,
            token: token,
            frontmostRoot: frontmostRoot,
            transform: transform,
            deadline: deadline
        ))
    }

    /// Grid step / point cap for the hit-test sweep. 32 pt is fine
    /// enough to land in a status-bar glyph or a tab-bar item without
    /// exploding the XPC count.
    private static let gridStep: Double = 32
    private static let gridCap: Int = 600
    /// The sweep can issue hundreds of XPC round-trips; bound its
    /// wall-clock so `describe-ui` stays responsive. The recursive
    /// walk already produced a usable tree — this only caps the
    /// *extra* hit-test work.
    private static let sweepBudgetSeconds: Double = 2.5
    /// Depth for a *sweep* hit-test: zero. Each grid point yields just
    /// the single deepest element under it; a deeper per-point walk
    /// fans out into dozens of XPC sub-requests, which is what made
    /// the sweep time out before reaching the bottom tab bar.
    private static let sweepDepth = 0

    private func fetchTree(hitTest: Point?) throws -> AXNode? {
        try withAXPContext { ctx in
            Self.stampElementTranslation(token: ctx.token, on: ctx.frontmostRoot)
            Self.stampSubtree(ctx.frontmostRoot, token: ctx.token, depthCap: Self.maxDepth)
            let base = AXNode.walk(
                from: ctx.frontmostRoot,
                transform: ctx.transform,
                depthCap: Self.maxDepth,
                deadline: ctx.deadline
            )
            // Only `describeAll` augments the walk with the sweep; the
            // `describeAt` fallback just needs the raw tree.
            guard hitTest == nil, Self.supportsServerSideHitTest else { return base }
            return hitTestSweep(base: base, ctx: ctx)
        }
    }

    /// Recover elements the process-scoped recursive walk can't reach
    /// — SpringBoard's status bar and the contents of childless
    /// containers (tab bars, nav bars, toolbars) — by hit-testing an
    /// `AXHitTestGrid` across the screen, then merging the discoveries
    /// into `base`.
    ///
    /// The grid skips only points inside genuine *content leaves*
    /// (`AXNode.contentLeafFrames`), never childless containers: an
    /// empty `AXGroup "Tab Bar"` is exactly where hit-test-only
    /// children live, so probing must continue inside it. Each hit-test
    /// is shallow (depth 0) so the full screen is covered fast, and the
    /// merge grafts every discovery under the deepest container that
    /// holds it — so a recovered tab-bar button is selectable rather
    /// than shadowed by its group.
    private func hitTestSweep(base: AXNode, ctx: AXPContext) -> AXNode {
        let pointSize = ctx.transform.pointSize
        let deadline = min(
            ctx.deadline,
            Date().addingTimeInterval(Self.sweepBudgetSeconds)
        )
        let grid = AXHitTestGrid(
            size: Size(width: pointSize.width, height: pointSize.height),
            step: Self.gridStep, cap: Self.gridCap
        )
        var discovered: [AXNode] = []
        var probed = 0
        for point in grid.samplePoints(covered: base.contentLeafFrames()) {
            if Date() >= deadline { break }
            probed += 1
            if let node = discover(at: point, ctx: ctx, depthCap: Self.sweepDepth) {
                discovered.append(node)
            }
        }
        let merged = base.merging(discovered: discovered)
        log("[ax] hit-test sweep: probed=\(probed) discovered=\(discovered.count)")
        return merged
    }

    /// Resolve the deepest accessibility element at a single
    /// device-point `point` via the server-side hit-test, returning it
    /// (walked `depthCap` levels deep) as an `AXNode`. Shared by the
    /// `describeAt` server-side path (full depth) and the `describeAll`
    /// hit-test sweep (depth 0). `objectAtPoint:displayId:bridgeDelegateToken:`
    /// is the 3-arg form (token as a parameter, so it plays nicely
    /// with the dispatcher); it returns the deepest element under the
    /// point and crosses process boundaries — which is how the
    /// SpringBoard status bar and childless-container contents
    /// (tab-bar items inside an empty `AXGroup`) surface at all.
    /// Discovered in Meta's idb (`FBSimulatorAccessibilityCommands.m`),
    /// which backs its describe-point CLI with the same selector.
    private func discover(at point: Point, ctx: AXPContext, depthCap: Int) -> AXNode? {
        let hostPoint = ctx.transform.unmap(CGPoint(x: point.x, y: point.y))
        guard let hitTranslation = Self.objectAtPoint(
            translator: ctx.translator, point: hostPoint,
            displayId: 0, token: ctx.token
        ) else { return nil }
        Self.stamp(token: ctx.token, on: hitTranslation)

        guard let hitElement = Self.macPlatformElement(
            translator: ctx.translator, translation: hitTranslation
        ) else { return nil }
        Self.stampElementTranslation(token: ctx.token, on: hitElement)
        // Only stamp the subtree when we'll actually walk it — a
        // shallow (depth 0) sweep hit reads no children.
        if depthCap > 0 {
            Self.stampSubtree(hitElement, token: ctx.token, depthCap: depthCap)
        }

        return AXNode.walk(
            from: hitElement,
            transform: ctx.transform,
            depthCap: depthCap,
            deadline: ctx.deadline
        )
    }

    private func hitTestServerSide(point: Point) throws -> AXNode? {
        // No element under the point returns nil — distinct from
        // "selector missing", which is gated by
        // `supportsServerSideHitTest` upstream. `describeAt` keeps the
        // full-depth walk so a single-point caller still gets the
        // element's subtree.
        try withAXPContext { ctx in discover(at: point, ctx: ctx, depthCap: Self.maxDepth) }
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

    /// 3-arg `objectAtPoint:displayId:bridgeDelegateToken:`. The
    /// older 0-arg `objectAtPoint:` variant needs the bridge token
    /// stamped on the returned translation *before* the call —
    /// chicken/egg. This 3-arg form takes the token as a parameter,
    /// so the dispatcher entry registered in `hitTestServerSide`
    /// resolves correctly on the very first XPC sub-request. Used
    /// by Meta's idb internally
    /// (`FBSimulatorAccessibilityCommands.m`, `FBAXTranslationRequest_Point`),
    /// where it's the foundation for the describe-point CLI.
    private static func objectAtPoint(
        translator: NSObject, point: CGPoint, displayId: UInt32, token: String
    ) -> NSObject? {
        let sel = NSSelectorFromString("objectAtPoint:displayId:bridgeDelegateToken:")
        guard translator.responds(to: sel),
              let imp = class_getMethodImplementation(type(of: translator), sel) else {
            logErr("[ax] -objectAtPoint:displayId:bridgeDelegateToken: not found")
            return nil
        }
        typealias Fn = @convention(c) (AnyObject, Selector, CGPoint, UInt32, AnyObject) -> AnyObject?
        return unsafeBitCast(imp, to: Fn.self)(
            translator, sel, point, displayId, token as NSString
        ) as? NSObject
    }

    /// Capability check: `true` when the loaded AXPTranslator
    /// responds to the 3-arg `objectAtPoint` selector. Lets
    /// `describeAt(point:)` choose between the new server-side
    /// path and the legacy client-side walk without a try-and-fall-back
    /// dance — the two paths cost the same on a hit but cost
    /// double on a miss, so a single capability check up front is
    /// cleaner. The selector has been present on every AXP we've
    /// seen on Xcode 26+; this guard is defensive only.
    static var supportsServerSideHitTest: Bool {
        guard let translator = sharedTranslator else { return false }
        return translator.responds(
            to: NSSelectorFromString("objectAtPoint:displayId:bridgeDelegateToken:")
        )
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
