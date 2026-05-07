import Foundation
import CoreGraphics
import ApplicationServices

/// Production `Accessibility` for native macOS apps. One-shot
/// fetch: `AXUIElementCreateApplication(pid)` returns the root
/// element, then `AXUIWalker.walk` (Domain) drives the recursion
/// via injected closures.
///
/// All real `AXUIElementCopyAttributeValue` calls live in the
/// `AXUIReader` closures below — those are integration-only.
/// Tests for the walker use a fake `AXUIReader<FakeElement>`,
/// keeping Domain logic at 100% unit coverage.
///
/// Coordinates: AX returns frames in **screen-global** points
/// (top-left origin on the primary display, accounting for
/// multi-monitor layouts). The walker accepts an `originOffset`
/// so the caller can choose between screen-global frames (default)
/// or window-relative frames (subtract the window's origin).
/// `describeAll` defaults to window-relative frames anchored at
/// the frontmost window so the JSON aligns with a window-cropped
/// screenshot — agents can read a frame off describe-ui and tap
/// it without coordinate juggling.
///
/// Both verbs return `nil` when the app has no accessible window
/// (just-launched apps that haven't built their AX tree yet).
/// Throws `MacAppError.tccDenied(scope: .accessibility)` when
/// `AXIsProcessTrusted()` is false on the first probe — the CLI
/// surfaces a clear hint pointing to System Settings.
final class AXUIElementAccessibility: Accessibility, @unchecked Sendable {
    private let pid: pid_t

    init(pid: pid_t) {
        self.pid = pid
    }

    func describeAll() throws -> AXNode? {
        try ensureTrusted()
        guard let window = frontmostWindow() else { return nil }
        let reader = Self.makeReader()
        let originOffset = reader.frame(window).origin
        return AXUIWalker.walk(
            from: window,
            reader: reader,
            originOffset: originOffset
        )
    }

    func describeAt(point: Point) throws -> AXNode? {
        // Like the iOS path, hit-test post-fetch: the AX
        // `kAXChildAtPointParameterizedAttribute` round-trip is
        // unreliable in practice. The walker is cheap.
        guard let tree = try describeAll() else { return nil }
        return tree.hitTest(point) ?? tree
    }

    // MARK: - integration-only AX I/O

    private func ensureTrusted() throws {
        if !AXIsProcessTrusted() {
            throw MacAppError.tccDenied(scope: .accessibility)
        }
    }

    /// First window of the running app's accessibility tree, if any.
    /// We prefer the focused window (`kAXFocusedWindowAttribute`)
    /// and fall back to the first entry in the windows array.
    private func frontmostWindow() -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)

        // Try the focused window first.
        var focused: AnyObject?
        if AXUIElementCopyAttributeValue(
            app, kAXFocusedWindowAttribute as CFString, &focused
        ) == .success, let focused {
            return (focused as! AXUIElement)
        }

        // Fall back to the first window in the app's window list.
        var windows: AnyObject?
        if AXUIElementCopyAttributeValue(
            app, kAXWindowsAttribute as CFString, &windows
        ) == .success,
           let arr = windows as? [AXUIElement],
           let first = arr.first {
            return first
        }
        return nil
    }

    /// Production `AXUIReader<AXUIElement>` — every closure is one
    /// `AXUIElementCopyAttributeValue` call. Static so the walker
    /// allocations don't carry per-instance state.
    private static func makeReader() -> AXUIReader<AXUIElement> {
        AXUIReader<AXUIElement>(
            role:       { copyString($0, kAXRoleAttribute) },
            subrole:    { copyString($0, kAXSubroleAttribute) },
            label:      { copyString($0, kAXDescriptionAttribute) },
            value:      { copyStringOrNumber($0, kAXValueAttribute) },
            identifier: { copyString($0, kAXIdentifierAttribute) },
            title:      { copyString($0, kAXTitleAttribute) },
            help:       { copyString($0, kAXHelpAttribute) },
            enabled:    { copyBool($0, kAXEnabledAttribute, default: true) },
            focused:    { copyBool($0, kAXFocusedAttribute, default: false) },
            hidden:     { copyBool($0, kAXHiddenAttribute, default: false) },
            frame:      { copyFrame($0) },
            children:   { copyChildren($0) }
        )
    }
}

// MARK: - AXValue / attribute extractors (integration-only)

private func copyAttribute(_ elem: AXUIElement, _ attr: String) -> AnyObject? {
    var value: AnyObject?
    let err = AXUIElementCopyAttributeValue(elem, attr as CFString, &value)
    return err == .success ? value : nil
}

private func copyString(_ elem: AXUIElement, _ attr: String) -> String? {
    guard let v = copyAttribute(elem, attr) as? String, !v.isEmpty else {
        return nil
    }
    return v
}

private func copyStringOrNumber(_ elem: AXUIElement, _ attr: String) -> String? {
    guard let v = copyAttribute(elem, attr) else { return nil }
    if let s = v as? String { return s.isEmpty ? nil : s }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}

private func copyBool(
    _ elem: AXUIElement, _ attr: String, default fallback: Bool
) -> Bool {
    guard let v = copyAttribute(elem, attr) as? NSNumber else { return fallback }
    return v.boolValue
}

private func copyFrame(_ elem: AXUIElement) -> CGRect {
    var posValue: AnyObject?
    var sizeValue: AnyObject?
    _ = AXUIElementCopyAttributeValue(elem, kAXPositionAttribute as CFString, &posValue)
    _ = AXUIElementCopyAttributeValue(elem, kAXSizeAttribute as CFString, &sizeValue)

    var pos = CGPoint.zero
    var size = CGSize.zero
    if let posValue {
        // `AXValueGetValue` writes through the typed pointer.
        AXValueGetValue(posValue as! AXValue, .cgPoint, &pos)
    }
    if let sizeValue {
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    }
    return CGRect(origin: pos, size: size)
}

private func copyChildren(_ elem: AXUIElement) -> [AXUIElement] {
    guard let raw = copyAttribute(elem, kAXChildrenAttribute) else { return [] }
    if let arr = raw as? [AXUIElement] { return arr }
    return []
}
