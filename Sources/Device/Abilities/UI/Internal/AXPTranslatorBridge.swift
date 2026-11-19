import AppKit
import Foundation

/// Apple's accessibility translator (`AXPTranslator`, private
/// AccessibilityPlatformTranslation), shared by every family that reads an
/// iOS accessibility tree on this Mac: it turns translator objects into
/// `AXPMacPlatformElement`s, asking each question of whatever source the
/// bridge token names — a simulator over XPC, or a phone's pushed tree.
/// Integration-only.
public enum AXPTranslatorBridge {

    nonisolated(unsafe) private static let frameworksLoaded: Bool = {
        let path = "/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation"
        if dlopen(path, RTLD_NOW | RTLD_GLOBAL) == nil {
            logErr("[ax] AccessibilityPlatformTranslation dlopen failed: \(dlerrorString())")
            return false
        }
        return true
    }()

    public nonisolated(unsafe) static let translator: NSObject? = {
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
        inst.setValue(dispatcher, forKey: "bridgeTokenDelegate")
        trace("[ax] AXPTranslator wired with bridgeTokenDelegate")
        return inst
    }()

    public nonisolated(unsafe) static let dispatcher = TokenDispatcher()


    public static func macPlatformElement(
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
public final class TokenDispatcher: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var deviceForToken: [String: NSObject] = [:]
    private var deadlineForToken: [String: Date] = [:]
    private var sourceForToken: [String: @Sendable (AnyObject) -> AnyObject?] = [:]

    public func register(device: NSObject, token: String, deadline: Date) {
        lock.lock(); defer { lock.unlock() }
        deviceForToken[token] = device
        deadlineForToken[token] = deadline
    }

    /// Answer every translator request for `token` from `source` — a
    /// phone's pushed tree, for instance — instead of a SimDevice. Nil from
    /// `source` answers empty.
    public func register(token: String, deadline: Date, source: @escaping @Sendable (AnyObject) -> AnyObject?) {
        lock.lock(); defer { lock.unlock() }
        sourceForToken[token] = source
        deadlineForToken[token] = deadline
    }

    public func unregister(token: String) {
        lock.lock(); defer { lock.unlock() }
        deviceForToken.removeValue(forKey: token)
        deadlineForToken.removeValue(forKey: token)
        sourceForToken.removeValue(forKey: token)
    }

    /// The registered source's answer to `request`, or empty without one.
    public func answer(_ request: AnyObject, forToken token: String) -> AnyObject {
        source(token: token)?(request) ?? TokenDispatcher.emptyResponse()
    }

    private func source(token: String) -> (@Sendable (AnyObject) -> AnyObject?)? {
        lock.lock(); defer { lock.unlock() }
        return sourceForToken[token]
    }

    private func lookup(token: String) -> (NSObject, Date)? {
        lock.lock(); defer { lock.unlock() }
        guard let dev = deviceForToken[token] else { return nil }
        return (dev, deadlineForToken[token] ?? Date.distantFuture)
    }

    @objc public dynamic func accessibilityTranslationDelegateBridgeCallbackWithToken(
        _ token: NSString
    ) -> Any {
        let key = token as String
        if self.source(token: key) != nil {
            let block: @convention(block) (AnyObject) -> AnyObject = { [weak self] request in
                self?.answer(request, forToken: key) ?? TokenDispatcher.emptyResponse()
            }
            return block
        }
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

    @objc public dynamic func accessibilityTranslationConvertPlatformFrameToSystem(
        _ rect: CGRect, withToken token: NSString
    ) -> CGRect {
        rect
    }

    @objc public dynamic func accessibilityTranslationRootParentWithToken(
        _ token: NSString
    ) -> AnyObject? {
        nil
    }

    /// The translation of one guest application, requested from its
    /// SimDevice directly. AXPTranslator's own PID convenience sends an
    /// empty bridge token, which cannot tell concurrent devices apart.
    public func application(
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
    public static func applicationRequest(pid: Int32) -> NSObject? {
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
    public static func emptyResponse() -> AnyObject {
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
