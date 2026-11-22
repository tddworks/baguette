import ApplicationServices
import BaguetteDevice
import CoreGraphics
import Foundation

/// The Mac's window server, told events through `CGEvent`. Refuses — posts
/// nothing — while this process isn't trusted for Accessibility, and asks for
/// it once. Integration-only: what each gesture becomes is `DisplayEvents`'.
struct CGEventHostEvents: HostEvents {
    func post(_ events: [HostEvent]) -> Bool {
        guard trusted() else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
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
        let prompt = "AXTrustedCheckOptionPrompt"  // kAXTrustedCheckOptionPrompt, a global Swift 6 won't read
        guard AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary) else {
            log("[mac] input refused: allow the app that runs baguette in System Settings › Privacy & Security › Accessibility")
            return false
        }
        return true
    }
}
