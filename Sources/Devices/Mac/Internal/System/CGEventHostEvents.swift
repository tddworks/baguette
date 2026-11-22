import ApplicationServices
import BaguetteDevice
import CoreGraphics
import Foundation

/// The Mac's window server, told events through `CGEvent`. Refuses — posts
/// nothing — while this process isn't trusted for Accessibility, asking once;
/// once trusted it isn't asked again, and one event source serves every event
/// (a pointer move costs ~0.2 ms, not the ~1.4 ms of asking each time).
/// Integration-only: what each gesture becomes is `DisplayEvents`'.
final class CGEventHostEvents: HostEvents, @unchecked Sendable {
    private let lock = NSLock()
    private var isTrusted = false
    private var asked = false
    private let source = CGEventSource(stateID: .hidSystemState)

    func post(_ events: [HostEvent]) -> Bool {
        guard trusted() else { return false }
        for event in events {
            switch event {
            case let .pause(seconds):
                if seconds > 0 { Thread.sleep(forTimeInterval: seconds) }
            case let .mouseDown(at): mouse(.leftMouseDown, at, source)
            case let .mouseDragged(at): mouse(.leftMouseDragged, at, source)
            case let .mouseUp(at): mouse(.leftMouseUp, at, source)
            case let .scroll(at, dx, dy):
                let scroll = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                     wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0)
                if let at { scroll?.location = CGPoint(x: at.x, y: at.y) }
                scroll?.post(tap: .cghidEventTap)
            case let .key(code, down, held):
                let key = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
                key?.flags = flags(held)
                key?.post(tap: .cghidEventTap)
            case let .text(text):
                let units = Array(text.utf16)
                for down in [true, false] {
                    let key = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                    key?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    key?.post(tap: .cghidEventTap)
                }
            }
        }
        return true
    }

    private func mouse(_ type: CGEventType, _ at: Point, _ source: CGEventSource?) {
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: CGPoint(x: at.x, y: at.y),
                mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private func flags(_ held: Set<KeyModifier>) -> CGEventFlags {
        held.reduce(into: CGEventFlags()) { flags, modifier in
            switch modifier {
            case .shift: flags.insert(.maskShift)
            case .control: flags.insert(.maskControl)
            case .option: flags.insert(.maskAlternate)
            case .command: flags.insert(.maskCommand)
            }
        }
    }

    private func trusted() -> Bool {
        if lock.withLock({ isTrusted }) { return true }
        let ask = lock.withLock { defer { asked = true }; return !asked }
        let prompt = "AXTrustedCheckOptionPrompt"  // kAXTrustedCheckOptionPrompt, a global Swift 6 won't read
        let now = ask ? AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary) : AXIsProcessTrusted()
        guard now else {
            log("[mac] input refused: allow the app that runs baguette in System Settings › Privacy & Security › Accessibility")
            return false
        }
        lock.withLock { isTrusted = true }
        return true
    }
}
