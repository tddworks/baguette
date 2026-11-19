import Foundation
import ObjectiveC

/// Messages to CoreSimulator / SimulatorKit objects whose signatures
/// `perform(_:)` can't carry — an `NSError **` out-parameter, a `BOOL`
/// answer, five object arguments. Each looks up the method's IMP and calls
/// it as the C function it is; what to send, and what an answer means,
/// belongs to the caller.

func invokeBoolWithError(_ target: NSObject, _ sel: Selector, _ err: inout NSError?) -> Bool {
    guard let imp = class_getMethodImplementation(type(of: target), sel) else { return false }
    typealias Fn = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>) -> Bool
    return unsafeBitCast(imp, to: Fn.self)(target, sel, &err)
}

func invokeBoolWithObjAndError(
    _ target: NSObject, _ sel: Selector, _ arg: AnyObject, _ err: inout NSError?
) -> Bool {
    guard let imp = class_getMethodImplementation(type(of: target), sel) else { return false }
    typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>) -> Bool
    return unsafeBitCast(imp, to: Fn.self)(target, sel, arg, &err)
}

func invokeObjWithError(_ target: NSObject, _ sel: Selector, _ err: inout NSError?) -> NSObject? {
    guard let imp = class_getMethodImplementation(type(of: target), sel) else { return nil }
    typealias Fn = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>) -> AnyObject?
    return unsafeBitCast(imp, to: Fn.self)(target, sel, &err) as? NSObject
}

func invokeObjWithObjAndError(
    _ target: NSObject, _ sel: Selector, _ arg: AnyObject, _ err: inout NSError?
) -> NSObject? {
    guard let imp = class_getMethodImplementation(type(of: target), sel) else { return nil }
    typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>)
        -> AnyObject?
    return unsafeBitCast(imp, to: Fn.self)(target, sel, arg, &err) as? NSObject
}

func invokeClassObjWithObjAndError(
    _ cls: AnyClass, _ sel: Selector, _ arg: AnyObject, _ err: inout NSError?
) -> NSObject? {
    guard let metaCls = object_getClass(cls), let imp = class_getMethodImplementation(metaCls, sel) else {
        return nil
    }
    typealias Fn = @convention(c) (AnyClass, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>)
        -> AnyObject?
    return unsafeBitCast(imp, to: Fn.self)(cls, sel, arg, &err) as? NSObject
}

/// A message of five object arguments and no answer — SimulatorKit's
/// `registerScreenCallbacksWithUUID:callbackQueue:frameCallback:…`.
/// `false` when the target has no implementation to call.
func invokeVoidWithFiveObjs(
    _ target: NSObject, _ sel: Selector,
    _ a: AnyObject, _ b: AnyObject, _ c: AnyObject, _ d: AnyObject, _ e: AnyObject
) -> Bool {
    guard let imp = class_getMethodImplementation(type(of: target), sel) else { return false }
    typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, AnyObject, AnyObject, AnyObject, AnyObject) -> Void
    unsafeBitCast(imp, to: Fn.self)(target, sel, a, b, c, d, e)
    return true
}
