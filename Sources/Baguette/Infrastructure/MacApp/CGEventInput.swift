import Foundation
import CoreGraphics
import ApplicationServices

/// Production `Input` for native macOS apps — wraps CoreGraphics
/// `CGEventCreate*` + `CGEventPost`.
///
/// Wire coordinates are **window-relative** points (top-left of
/// the target app's frontmost window content rect = (0, 0)).
/// The adapter resolves the window's screen-global origin via
/// `AXUIElement` once per gesture, adds it to the wire point, then
/// posts. Resolving every call (rather than caching) costs ~0.5ms
/// but keeps the adapter correct when the user drags the window
/// between gestures.
///
/// Stage-2 scope:
///   - Implemented: `tap`, `swipe`, `scroll`, `key` (+ `type` via
///     the existing `TypeText` gesture which decomposes into
///     `key` calls).
///   - Rejected (with a log line): `touch1`, `touch2`,
///     `twoFingerPath` — multi-touch via `CGEvent` isn't reliable
///     for app-level testing on macOS. `button` — hardware
///     buttons (home / power / volume) don't apply to macOS apps.
///
/// Every entry point logs an `[mac-input]` line at branch points
/// so users can see where dispatch went. Integration-only — the
/// `CGEventPost` calls are the irreducible OS boundary.
final class CGEventInput: Input, @unchecked Sendable {
    private let pid: pid_t

    init(pid: pid_t) {
        self.pid = pid
        Self.probeAXTrustOnce
    }

    /// One-shot diagnostic: log whether the process is currently
    /// trusted for AX / event posting. Silent failure of
    /// `CGEventPost` / `postToPid` is almost always TCC denial; this
    /// log line gives users an immediate hint at what's wrong.
    /// Shared `CGEventSource` for every event we create. `cliclick`,
    /// `xdotool`-style helpers, and Apple's own scripting bridge all
    /// post events with an explicit `kCGEventSourceStateHIDSystemState`
    /// source — events created with a `nil` source can be silently
    /// filtered by some apps' event-monitoring chains.
    private nonisolated(unsafe) static let eventSource: CGEventSource? =
        CGEventSource(stateID: .hidSystemState)

    private static let probeAXTrustOnce: Void = {
        let trusted = AXIsProcessTrusted()
        log("[mac-input] AXIsProcessTrusted=\(trusted) " +
            "(events post to other apps require Accessibility grant in System Settings → Privacy & Security)")
    }()

    // MARK: - mouse gestures

    func tap(at point: Point, size: Size, duration: Double) -> Bool {
        guard let origin = windowOrigin() else {
            log("[mac-input] tap: no window for pid=\(pid)")
            return false
        }
        let screenPoint = CGPoint(x: point.x + origin.x, y: point.y + origin.y)
        let hold = duration > 0 ? duration : 0.05

        // Mouse events need the actual cursor at the click location
        // (apps' hit-testing reads it). Without the warp, posting a
        // click at (10, 50) while the user's cursor is at (700, 700)
        // produces an event the app silently ignores.
        CGWarpMouseCursorPosition(screenPoint)

        guard let down = CGEvent(
            mouseEventSource: Self.eventSource, mouseType: .leftMouseDown,
            mouseCursorPosition: screenPoint, mouseButton: .left
        ) else {
            log("[mac-input] tap: CGEvent leftMouseDown failed")
            return false
        }
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: hold)
        guard let up = CGEvent(
            mouseEventSource: Self.eventSource, mouseType: .leftMouseUp,
            mouseCursorPosition: screenPoint, mouseButton: .left
        ) else {
            log("[mac-input] tap: CGEvent leftMouseUp failed")
            return false
        }
        up.post(tap: .cghidEventTap)
        return true
    }

    func swipe(from start: Point, to end: Point, size: Size, duration: Double) -> Bool {
        guard let origin = windowOrigin() else {
            log("[mac-input] swipe: no window for pid=\(pid)")
            return false
        }
        let screenStart = CGPoint(x: start.x + origin.x, y: start.y + origin.y)
        let screenEnd   = CGPoint(x: end.x   + origin.x, y: end.y   + origin.y)

        // 30 interpolated drags in 250 ms by default — matches the
        // iOS path's perceptual speed.
        let samples = max(2, Int((duration > 0 ? duration : 0.25) * 120))
        let total = duration > 0 ? duration : 0.25
        let stepDelay = total / Double(samples)

        // Warp ONCE so the initial mouseDown lands on the right
        // character; subsequent `mouseDragged` events carry their own
        // `mouseCursorPosition` and the OS moves the cursor along
        // with them. Warping inside the drag loop races with the
        // dragged events and causes TextEdit to lose the drag
        // session.
        CGWarpMouseCursorPosition(screenStart)
        guard let down = CGEvent(
            mouseEventSource: Self.eventSource, mouseType: .leftMouseDown,
            mouseCursorPosition: screenStart, mouseButton: .left
        ) else { return false }
        down.post(tap: .cghidEventTap)
        // Apps need a beat to enter drag-select mode after a mouseDown
        // before they'll honour subsequent mouseDragged events as a
        // drag (rather than coalescing them with the down).
        Thread.sleep(forTimeInterval: 0.05)

        for i in 1..<samples {
            let t = Double(i) / Double(samples - 1)
            let p = CGPoint(
                x: screenStart.x + (screenEnd.x - screenStart.x) * t,
                y: screenStart.y + (screenEnd.y - screenStart.y) * t
            )
            if let drag = CGEvent(
                mouseEventSource: Self.eventSource, mouseType: .leftMouseDragged,
                mouseCursorPosition: p, mouseButton: .left
            ) {
                drag.post(tap: .cghidEventTap)
            }
            Thread.sleep(forTimeInterval: stepDelay)
        }

        guard let up = CGEvent(
            mouseEventSource: Self.eventSource, mouseType: .leftMouseUp,
            mouseCursorPosition: screenEnd, mouseButton: .left
        ) else { return false }
        up.post(tap: .cghidEventTap)
        return true
    }

    func scroll(deltaX: Double, deltaY: Double) -> Bool {
        // Park the cursor over the target window's centre so the
        // scroll event lands inside it. CGEvent scroll routes via
        // the WindowServer to the window under the cursor; without
        // this warp a scroll could end up applying to whatever
        // window the user happens to be hovering.
        if let origin = windowOrigin(),
           let windowSize = focusedWindowSize() {
            CGWarpMouseCursorPosition(CGPoint(
                x: origin.x + windowSize.width / 2,
                y: origin.y + windowSize.height / 2
            ))
        }

        // CGEvent scroll is in pixel units (line-style would be
        // integer wheel ticks); pass through whatever the wire gave
        // us. WheelCount = 2 so vertical (wheel1) and horizontal
        // (wheel2) deltas both ride one event.
        guard let event = CGEvent(
            scrollWheelEvent2Source: Self.eventSource,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(deltaY), wheel2: Int32(deltaX), wheel3: 0
        ) else {
            log("[mac-input] scroll: CGEvent scroll failed")
            return false
        }
        event.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - keyboard

    func key(_ key: KeyboardKey, modifiers: Set<KeyModifier>, duration: Double) -> Bool {
        guard let code = key.macKeyCode else {
            log("[mac-input] key: no macOS virt-key for HID page=\(key.hidUsage.page) usage=0x\(String(key.hidUsage.usage, radix: 16))")
            return false
        }
        let hold = duration > 0 ? duration : 0.05
        let flags = CGEventFlags(rawValue: KeyModifier.combinedFlag(of: modifiers))

        guard let down = CGEvent(
            keyboardEventSource: Self.eventSource, virtualKey: code, keyDown: true
        ) else { return false }
        down.flags = flags
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: hold)
        guard let up = CGEvent(
            keyboardEventSource: Self.eventSource, virtualKey: code, keyDown: false
        ) else { return false }
        up.flags = flags
        up.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - rejected (logged)

    func touch1(phase: GesturePhase, at point: Point, size: Size) -> Bool {
        reject("touch1 (multi-touch via CGEvent isn't supported for macOS apps)")
    }
    func touch2(phase: GesturePhase, first: Point, second: Point, size: Size) -> Bool {
        reject("touch2 (multi-touch via CGEvent isn't supported for macOS apps)")
    }
    func button(_ button: DeviceButton, duration: Double) -> Bool {
        reject("button (hardware buttons don't apply to macOS apps)")
    }
    func twoFingerPath(
        start1: Point, end1: Point,
        start2: Point, end2: Point,
        size: Size, duration: Double
    ) -> Bool {
        reject("twoFingerPath (multi-touch via CGEvent isn't supported for macOS apps)")
    }

    private func reject(_ reason: String) -> Bool {
        log("[mac-input] rejecting: \(reason)")
        return false
    }

    // MARK: - private — AX window origin lookup

    /// Screen-global top-left of the target app's frontmost window's
    /// content rect, or `nil` when the app has no on-screen window.
    /// Looks up via AX every call — cheap (~0.5 ms) and stays
    /// correct when the user drags the window between gestures.
    private func windowOrigin() -> CGPoint? {
        let app = AXUIElementCreateApplication(pid)
        var focused: AnyObject?
        if AXUIElementCopyAttributeValue(
            app, kAXFocusedWindowAttribute as CFString, &focused
        ) == .success, let focused {
            return windowOrigin(of: focused as! AXUIElement)
        }
        var windows: AnyObject?
        if AXUIElementCopyAttributeValue(
            app, kAXWindowsAttribute as CFString, &windows
        ) == .success,
           let arr = windows as? [AXUIElement],
           let first = arr.first {
            return windowOrigin(of: first)
        }
        return nil
    }

    /// Size of the target app's frontmost window (content rect),
    /// or `nil` when no window is reachable. Used by `scroll` to
    /// park the cursor at the window centre before posting.
    private func focusedWindowSize() -> CGSize? {
        let app = AXUIElementCreateApplication(pid)
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(
            app, kAXFocusedWindowAttribute as CFString, &focused
        ) == .success, let focused else {
            return nil
        }
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            focused as! AXUIElement, kAXSizeAttribute as CFString, &sizeValue
        ) == .success, let sizeValue else {
            return nil
        }
        var size = CGSize.zero
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return size
    }

    private func windowOrigin(of window: AXUIElement) -> CGPoint? {
        var posValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            window, kAXPositionAttribute as CFString, &posValue
        ) == .success, let posValue else {
            return nil
        }
        var pos = CGPoint.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &pos)
        return pos
    }
}
