import Foundation
import ObjectiveC
import CoreGraphics

/// KVC + ObjC-runtime helpers for reading standard
/// `AXPMacPlatformElement` properties off any `NSObject`.
///
/// Lives in Domain (not Infrastructure) because it talks only to
/// the public ObjC runtime — it doesn't know about
/// `AXPTranslator`, `AXPMacPlatformElement`, or any private
/// framework symbol. That makes the walk-tree-into-`AXNode`
/// logic a pure function the `AXPTranslatorAccessibility`
/// adapter can drive once it's pulled the root element back from
/// the AX XPC round-trip.
///
/// Tests cover this through `AXNode.walk(...)` against
/// `FakeAXTreeElement` `NSObject` subclasses that override the
/// same selectors / KVC keys the production element responds to.
enum AXElementReader {

    /// Non-empty string-valued property; returns `nil` for
    /// missing keys, non-string values, or empty strings.
    static func string(_ obj: NSObject, _ key: String) -> String? {
        guard let s = obj.value(forKey: key) as? String, !s.isEmpty else { return nil }
        return s
    }

    /// Like `string(_:_:)` but coerces `NSNumber` into its
    /// `stringValue`. Some accessibility-value properties return
    /// numbers (sliders, progress views, page pickers); we surface
    /// them as plain strings in the JSON so the column shape is
    /// stable.
    static func stringOrNumber(_ obj: NSObject, _ key: String) -> String? {
        let raw = obj.value(forKey: key)
        if let s = raw as? String { return s.isEmpty ? nil : s }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }

    /// Bool-valued property; returns `fallback` when the key is
    /// missing or holds a non-NSNumber value.
    static func bool(_ obj: NSObject, _ key: String, default fallback: Bool) -> Bool {
        if let n = obj.value(forKey: key) as? NSNumber { return n.boolValue }
        return fallback
    }

    /// `accessibilityFrame` is a CGRect-returning Objective-C
    /// method, which can't ride through KVC's type-erased return —
    /// resolve via `class_getMethodImplementation` and a typed
    /// function-pointer cast. Returns `.zero` when the element
    /// doesn't respond to the selector.
    static func frame(of element: NSObject) -> CGRect {
        let sel = NSSelectorFromString("accessibilityFrame")
        guard element.responds(to: sel),
              let imp = class_getMethodImplementation(type(of: element), sel) else {
            return .zero
        }
        typealias Fn = @convention(c) (AnyObject, Selector) -> CGRect
        return unsafeBitCast(imp, to: Fn.self)(element, sel)
    }

    /// `accessibilityChildren` returns `[NSObject]` on real
    /// `AXPMacPlatformElement`s — we accept `nil`, an array of
    /// `NSObject` (the happy path), or anything else (treated as
    /// empty). Non-NSObject array entries are dropped silently.
    static func children(of element: NSObject) -> [NSObject] {
        guard let raw = element.value(forKey: "accessibilityChildren") else { return [] }
        if let arr = raw as? [NSObject] { return arr }
        return []
    }
}
