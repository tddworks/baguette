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
///   1. Find the frontmost PID. `describeAll` asks the bridge first and
///      falls back to a fresh `HingeControl frontmost` process
///      (`GuestFrontmost`) when the bridge can't read the app
///      (`AXFrontmostRead`): on iOS 26.5 its frontmost request can answer
///      empty, and a freshly launched app shows it an empty tree until a
///      guest accessibility client has connected. Point queries always
///      use the guest process.
///   2. Request that application's translation from the SimDevice
///      directly (`TokenDispatcher.application(pid:…)`).
///   3. Generate a fresh UUID token; register it → SimDevice in the
///      shared dispatcher, and set it as `bridgeDelegateToken` on the
///      translation — children inherit it, but the translator re-reads
///      it for every sub-request, so missing this means child element
///      reads silently fail.
///   4. Convert translation → `AXPMacPlatformElement` and walk
///      `accessibilityChildren`, propagating the token onto every
///      sub-translation.
///   5. Unregister on exit.
///
/// Coordinates: the bridge delegate leaves guest frames unchanged, so
/// AXP reports UIKit screen points. The observed display geometry
/// (native panel points plus the interface orientation) rotates them
/// into the native panel space that raw pixels and HID input share, so
/// callers can pipe values straight back into baguette's gesture wire.
/// The application root's bounds define neither the screen size nor a
/// scale: a hosted app can report a partial window.
///
/// Cribbed from cameroncooke/AXe + Silbercue/SilbercueSwift's
/// `AXPBridge.swift` — the only Swift implementations of the iOS-26
/// out-of-Simulator.app dispatcher pattern that we know of.
final class AXPTranslatorAccessibility: Accessibility, @unchecked Sendable {
    private let udid: String
    private let host: any DeviceHost
    private let deviceSetPath: String?

    /// Cap on tree-walk recursion depth. Real iOS screens rarely
    /// exceed 20–30 levels; the cap prevents pathological cycles.
    private static let maxDepth = 60

    /// Per-XPC-call timeout in seconds. The dispatcher's block waits
    /// synchronously on each request; keeping this short means a
    /// hung simulator doesn't pin our caller.
    private static let xpcTimeoutSeconds: Double = 5.0

    typealias DisplayGeometry = AXScreen

    /// The screen every result is expressed in: native panel points, the
    /// observed interface orientation and the connected screen's
    /// identity. Read before and after each query; a geometry that
    /// cannot be observed fails the query instead of guessing a phone
    /// size. Pluggable so tests can drive the transform without a
    /// display resolve.
    private let displayGeometry: @Sendable () throws -> DisplayGeometry

    /// The geometry read again after a query, to reject a result whose
    /// frames describe a screen that has since changed.
    private let recheckGeometry: @Sendable () throws -> DisplayGeometry

    /// The guest's current frontmost PID for a udid and device set;
    /// `GuestFrontmost.pid` in production, a stub in tests.
    private let frontmostPID: @Sendable (String, String?) throws -> Int32

    init(
        udid: String,
        host: any DeviceHost,
        deviceSetPath: String? = nil,
        frontmostPID: @escaping @Sendable (String, String?) throws -> Int32 = {
            try GuestFrontmost.pid(udid: $0, deviceSetPath: $1)
        },
        recheckGeometry: (@Sendable () throws -> DisplayGeometry)? = nil,
        displayGeometry: @escaping @Sendable () throws -> DisplayGeometry
    ) {
        self.udid = udid
        self.host = host
        self.deviceSetPath = deviceSetPath
        self.frontmostPID = frontmostPID
        self.displayGeometry = Self.retrying(displayGeometry)
        self.recheckGeometry = Self.retrying(recheckGeometry ?? displayGeometry)
    }

    /// The simulator sometimes can't report the screen for a moment, on a screen
    /// that reads fine right after, so a read gets a few tries before it fails.
    private static func retrying(
        _ read: @escaping @Sendable () throws -> DisplayGeometry
    ) -> @Sendable () throws -> DisplayGeometry {
        {
            var attempt = 1
            while true {
                do { return try read() } catch {
                    if attempt >= 4 { throw error }
                    attempt += 1
                    Thread.sleep(forTimeInterval: 0.15)
                }
            }
        }
    }

    private func resolveDevice() -> NSObject? {
        host.resolveDevice(udid: udid)
    }

    // MARK: - Accessibility

    func describeAll() throws -> AXNode? {
        guard Self.isAvailable else {
            logErr("[ax] framework / dispatcher not available")
            return nil
        }
        guard let device = resolveDevice() else {
            logErr("[ax] device not found: \(udid)")
            return nil
        }
        // A long-lived session already knows its panel, so only the first
        // read pays for listing the connected screens.
        let geometry = try recheckGeometry()
        return try AXFrontmostRead.read(
            bridge: { Self.bridgeFrontmostPID(device: device) },
            guest: { try frontmostPID(udid, deviceSetPath) },
            tree: { pid, source in
                try withAXPContext(known: (geometry, pid)) { ctx in
                    let base = walkFrontmost(ctx)
                    // An empty walk through the bridge is an app not yet
                    // awake, so the guest route reads it again: sweeping
                    // here would hide that behind the status bar's nodes.
                    if source == .bridge, base.children.isEmpty { return base }
                    return Self.supportsServerSideHitTest ? hitTestSweep(base: base, ctx: ctx) : base
                }
            })
    }

    func glance() throws -> AXNode? {
        guard Self.isAvailable, let device = resolveDevice() else { return nil }
        let geometry = try recheckGeometry()
        guard let pid = Self.bridgeFrontmostPID(device: device), pid > 0 else { return nil }
        return try withAXPContext(known: (geometry, pid)) { walkFrontmost($0) }
    }

    func wake() throws {
        _ = try frontmostPID(udid, deviceSetPath)
    }

    func press(_ node: AXNode) throws -> Bool {
        guard Self.isAvailable, let device = resolveDevice() else { return false }
        let geometry = try recheckGeometry()
        let bridged = Self.bridgeFrontmostPID(device: device).flatMap { $0 > 0 ? $0 : nil }
        let pid = try bridged ?? frontmostPID(udid, deviceSetPath)
        var pressed = false
        _ = try withAXPContext(known: (geometry, pid)) { ctx in
            Self.stampElementTranslation(token: ctx.token, on: ctx.frontmostRoot)
            Self.stampSubtree(ctx.frontmostRoot, token: ctx.token, depthCap: Self.maxDepth)
            var found: [(node: AXNode, element: NSObject)] = []
            Self.collectElements(under: ctx.frontmostRoot, ctx: ctx, depth: 0, into: &found)
            let match = node.bestMatch(among: found.map(\.node))
            if let element = found.first(where: { $0.node == match })?.element
                ?? hitElement(matching: node, screen: geometry, ctx: ctx)
            {
                pressed = Self.performPress(on: element)
            }
            return nil
        }
        return pressed
    }

    /// Every live element beside the node it reads as, so `bestMatch` can find the
    /// one that was asked for.
    private static func collectElements(
        under element: NSObject, ctx: AXPContext, depth: Int, into found: inout [(node: AXNode, element: NSObject)]
    ) {
        guard depth < maxDepth else { return }
        found.append((AXNode.walk(from: element, transform: ctx.transform, depthCap: 0), element))
        for child in AXElementReader.children(of: element) {
            collectElements(under: child, ctx: ctx, depth: depth + 1, into: &found)
        }
    }

    /// What only the sweep can reach, like a tab in a childless bar, found by
    /// position and checked to be the same element.
    private func hitElement(matching node: AXNode, screen: AXScreen, ctx: AXPContext) -> NSObject? {
        guard let point = node.touchPoint(on: screen) else { return nil }
        let hostPoint = ctx.transform.unmap(CGPoint(x: point.x, y: point.y))
        guard let translation = Self.objectAtPoint(translator: ctx.translator, point: hostPoint, displayId: 0, token: ctx.token)
        else { return nil }
        Self.stamp(token: ctx.token, on: translation)
        guard let element = Self.macPlatformElement(translator: ctx.translator, translation: translation) else { return nil }
        Self.stampElementTranslation(token: ctx.token, on: element)
        let hit = AXNode.walk(from: element, transform: ctx.transform, depthCap: 0, deadline: ctx.deadline)
        return node.bestMatch(among: [hit]) == nil ? nil : element
    }

    /// Returns a Bool, not an object, so it needs a typed call.
    private static func performPress(on element: NSObject) -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard element.responds(to: selector),
            let imp = class_getMethodImplementation(type(of: element), selector)
        else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(imp, to: Press.self)(element, selector)
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
        var result = tree.hitTest(point) ?? tree
        result.screen = tree.screen
        return result
    }

    // MARK: - tree fetch

    /// The pieces every AXP entry point needs: a working translator,
    /// a registered token, the frontmost app's root element, an
    /// `AXFrameTransform` for rotating UIKit points into native panel
    /// points and back, and the per-call deadline.
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
    /// UIKit-point → native-panel-point `AXFrameTransform` setup.
    /// Returns `nil` if any setup step fails (framework not loaded,
    /// device missing, no platform element for the translation); throws
    /// when the display geometry cannot be observed or changes during
    /// the read, and when the guest frontmost query or the application
    /// lookup fails, because those name a cause the caller can act on.
    private func withAXPContext(
        known: (geometry: DisplayGeometry, pid: Int32)? = nil,
        _ body: (AXPContext) throws -> AXNode?
    ) throws -> AXNode? {
        guard Self.isAvailable else {
            logErr("[ax] framework / dispatcher not available")
            return nil
        }
        guard let device = resolveDevice() else {
            logErr("[ax] device not found: \(udid)")
            return nil
        }
        let geometry = try known?.geometry ?? displayGeometry()
        let pid = try known?.pid ?? frontmostPID(udid, deviceSetPath)
        let translation = try Self.sharedDispatcher.application(
            pid: pid, on: device, udid: udid, timeout: Self.xpcTimeoutSeconds
        )
        // Discovery has its own bounded lifetime; the tree's deadline
        // starts once the root translation is in hand.
        let token = UUID().uuidString
        let deadline = Date().addingTimeInterval(Self.xpcTimeoutSeconds)
        Self.sharedDispatcher.register(device: device, token: token, deadline: deadline)
        defer { Self.sharedDispatcher.unregister(token: token) }

        guard let translator = Self.sharedTranslator else { return nil }

        Self.stamp(token: token, on: translation)

        guard let frontmostRoot = Self.macPlatformElement(
            translator: translator, translation: translation
        ) else {
            log("[ax] no mac platform element from translation")
            return nil
        }
        let transform = AXFrameTransform(
            pointSize: CGSize(width: geometry.width, height: geometry.height),
            orientation: geometry.orientation
        )

        var result = try body(AXPContext(
            translator: translator,
            token: token,
            frontmostRoot: frontmostRoot,
            transform: transform,
            deadline: deadline
        ))
        try Self.requireUnchanged(geometry, try recheckGeometry())
        result?.screen = geometry
        return result
    }

    /// A rotation or panel change during the read means the frames no
    /// longer describe the screen the result names. Matching endpoints
    /// do not make the guest's tree an atomic snapshot; they only rule
    /// out a transition the host could observe.
    static func requireUnchanged(_ before: DisplayGeometry, _ after: DisplayGeometry) throws {
        guard before == after else { throw Failure.displayChanged }
    }

    enum Failure: LocalizedError, Equatable {
        case displayChanged

        var errorDescription: String? {
            "The display changed while reading accessibility; discard the result and observe again."
        }
    }

    /// Grid step / point cap for the hit-test sweep. 32 pt is fine
    /// enough to land in a status-bar glyph or a tab-bar item without
    /// exploding the XPC count.
    private static let gridStep: Double = 32
    private static let gridCap: Int = 600
    /// Spacing of the coarse look at the gaps between known elements: fine
    /// enough to land on a block of web text, a quarter of the fine probes.
    private static let scoutStep: Double = 64
    /// How far down the status bar reaches: two grid rows, clear of the
    /// Dynamic Island's 49 pt.
    private static let statusStripHeight: CGFloat = 64
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
            // Only `describeAll` augments the walk with the sweep; the
            // `describeAt` fallback just needs the raw tree.
            walkFrontmost(ctx)
        }
    }

    private func walkFrontmost(_ ctx: AXPContext) -> AXNode {
        Self.stampElementTranslation(token: ctx.token, on: ctx.frontmostRoot)
        Self.stampSubtree(ctx.frontmostRoot, token: ctx.token, depthCap: Self.maxDepth)
        return AXNode.walk(
            from: ctx.frontmostRoot,
            transform: ctx.transform,
            depthCap: Self.maxDepth,
            deadline: ctx.deadline
        )
    }

    /// The bridge's own answer to "which app is frontmost?", or `nil` when
    /// it has none. Queried afresh on every read; `AXFrontmostRead` decides
    /// what an empty answer means.
    private static func bridgeFrontmostPID(device: NSObject) -> Int32? {
        let send = NSSelectorFromString("sendAccessibilityRequestAsync:completionQueue:completionHandler:")
        let frontmost = NSSelectorFromString("frontmostApplicationWithDisplayId:bridgeDelegateToken:")
        guard device.responds(to: send),
            let translator = sharedTranslator, translator.responds(to: frontmost),
            let imp = class_getMethodImplementation(type(of: translator), frontmost)
        else { return nil }
        let token = UUID().uuidString
        sharedDispatcher.register(device: device, token: token, deadline: Date().addingTimeInterval(xpcTimeoutSeconds))
        defer { sharedDispatcher.unregister(token: token) }
        typealias Fn = @convention(c) (AnyObject, Selector, UInt32, AnyObject) -> AnyObject?
        guard let translation = unsafeBitCast(imp, to: Fn.self)(translator, frontmost, 0, token as NSString) as? NSObject,
            translation.responds(to: NSSelectorFromString("pid"))
        else { return nil }
        return (translation.value(forKey: "pid") as? NSNumber)?.int32Value
    }

    /// Recover elements the process-scoped recursive walk can't reach
    /// — SpringBoard's status bar, the contents of childless containers
    /// (tab bars, nav bars, toolbars) and web content — by hit-testing
    /// where `AXSweep` says to look, then merging the discoveries into
    /// `base`. Each hit-test is shallow (depth 0) so the regions are
    /// covered fast, and the merge grafts every discovery under the
    /// deepest container that holds it — so a recovered tab-bar button is
    /// selectable rather than shadowed by its group.
    private func hitTestSweep(base: AXNode, ctx: AXPContext) -> AXNode {
        let pointSize = ctx.transform.pointSize
        let deadline = min(
            ctx.deadline,
            Date().addingTimeInterval(Self.sweepBudgetSeconds)
        )
        let size = Size(width: pointSize.width, height: pointSize.height)
        let strip = ctx.transform.topStrip(height: Self.statusStripHeight)
        let sweep = AXSweep.run(
            base: base,
            fine: AXHitTestGrid(size: size, step: Self.gridStep, cap: Self.gridCap),
            scout: AXHitTestGrid(size: size, step: Self.scoutStep, cap: Self.gridCap),
            statusStrip: Rect(
                origin: Point(x: Double(strip.origin.x), y: Double(strip.origin.y)),
                size: Size(width: Double(strip.size.width), height: Double(strip.size.height))),
            keepGoing: { Date() < deadline },
            probe: { discover(at: $0, ctx: ctx, depthCap: Self.sweepDepth) }
        )
        trace("[ax] hit-test sweep: probed=\(sweep.probed) discovered=\(sweep.discovered.count)")
        return base.merging(discovered: sweep.discovered)
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
        trace("[ax] AXPTranslator wired with bridgeTokenDelegate")
        return inst
    }()

    nonisolated(unsafe) static let sharedDispatcher = TokenDispatcher()

    // MARK: - AXPTranslator entry points

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

    /// The translation of one guest application, requested from its
    /// SimDevice directly. AXPTranslator's own PID convenience sends an
    /// empty bridge token, which cannot tell concurrent devices apart.
    func application(
        pid: Int32, on device: NSObject, udid: String, timeout: Double,
        request: (Int32) -> NSObject? = TokenDispatcher.applicationRequest
    ) throws -> NSObject {
        guard let request = request(pid) else {
            throw ApplicationFailure(udid: udid, pid: pid, cause: "AXPTranslatorRequest is unavailable")
        }
        guard let response = sendAccessibilityRequest(request, to: device, timeout: timeout) as? NSObject,
            let translation = response.value(forKey: "translationResponse") as? NSObject
        else {
            throw ApplicationFailure(udid: udid, pid: pid, cause: "the device returned no application translation")
        }
        return translation
    }

    /// AXP's application-by-PID request, as observed on the iOS 26 wire;
    /// `nil` when the framework's request class is not loaded.
    static func applicationRequest(pid: Int32) -> NSObject? {
        let selector = NSSelectorFromString("new")
        guard let cls = NSClassFromString("AXPTranslatorRequest"),
            let meta = object_getClass(cls),
            let imp = class_getMethodImplementation(meta, selector)
        else { return nil }
        typealias New = @convention(c) (AnyClass, Selector) -> Unmanaged<NSObject>
        let request = unsafeBitCast(imp, to: New.self)(cls, selector).takeRetainedValue()
        // A private class whose keys moved raises an uncatchable
        // NSUnknownKeyException from `setValue(forKey:)`; refuse instead.
        guard request.responds(to: NSSelectorFromString("setRequestType:")),
            request.responds(to: NSSelectorFromString("setParameters:"))
        else { return nil }
        request.setValue(1, forKey: "requestType")
        request.setValue(["pid": pid], forKey: "parameters")
        return request
    }

    private struct ApplicationFailure: LocalizedError {
        let udid: String
        let pid: Int32
        let cause: String
        var errorDescription: String? { "AX application lookup for \(udid) (PID \(pid)) failed: \(cause)" }
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
