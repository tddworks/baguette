import ApplicationServices
import BaguetteDevice
import CoreGraphics
import Foundation

/// The Mac's window server through `CGEvent`, one event source for every
/// event. Integration-only: what each gesture becomes is `DisplayEvents`',
/// when to post and when to ask for Accessibility `WindowServerEvents`'.
final class CGEventWindowServer: WindowServer, @unchecked Sendable {
    private let source = CGEventSource(stateID: .hidSystemState)

    func trusted(asking: Bool) -> Bool {
        let prompt = "AXTrustedCheckOptionPrompt"  // kAXTrustedCheckOptionPrompt, a global Swift 6 won't read
        return asking ? AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary) : AXIsProcessTrusted()
    }

    func post(_ event: HostEvent) {
        switch event {
        case .pause: break
        case let .mouseDown(at): mouse(.leftMouseDown, at)
        case let .mouseDragged(at): mouse(.leftMouseDragged, at)
        case let .mouseUp(at): mouse(.leftMouseUp, at)
        case let .mouseMoved(at): mouse(.mouseMoved, at)
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

    private func mouse(_ type: CGEventType, _ at: Point) {
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
}
