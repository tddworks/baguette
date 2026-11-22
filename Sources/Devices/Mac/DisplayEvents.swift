import BaguetteDevice
import Foundation

/// One event the Mac's window server is told, in the desktop's global points
/// (the main display's top-left at 0,0, y down) — or a pause between two.
enum HostEvent: Equatable, Sendable {
    case mouseDown(Point)
    case mouseDragged(Point)
    case mouseUp(Point)
    /// Content scrolls by `deltaX` / `deltaY` points; positive is up / left,
    /// the window server's sense.
    case scroll(deltaX: Double, deltaY: Double)
    /// A virtual key code going down or up, with the modifiers held as it does.
    case key(code: UInt16, down: Bool, held: Set<KeyModifier>)
    /// Text typed as it is, whatever its script.
    case text(String)
    case pause(Double)
}

/// What a gesture on one Mac display becomes: the events it is, placed on the
/// display at `bounds` (global points). A point arrives in device points
/// beside the size it was measured in, and lands at the same fraction of the
/// display. The Mac has one pointer: a finger is the mouse, and there is no
/// second one.
struct DisplayEvents: Equatable, Sendable {
    /// The longest a piece of typed text a keyboard event carries, in UTF-16.
    static let textPiece = 20
    /// Drag steps a second of swipe takes.
    static let dragsPerSecond = 60.0

    let bounds: Rect

    func tap(at point: Point, size: Size, duration: Double) -> [HostEvent] {
        let at = place(point, size)
        return [.mouseDown(at), .pause(duration), .mouseUp(at)]
    }

    func swipe(from start: Point, to end: Point, size: Size, duration: Double) -> [HostEvent] {
        let (from, to) = (place(start, size), place(end, size))
        let steps = max(1, Int(duration * Self.dragsPerSecond))
        let drags = (1...steps).flatMap { step -> [HostEvent] in
            let t = Double(step) / Double(steps)
            return [.pause(duration / Double(steps)),
                    .mouseDragged(Point(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))]
        }
        return [.mouseDown(from)] + drags + [.mouseUp(to)]
    }

    func touch1(phase: GesturePhase, at point: Point, size: Size) -> [HostEvent] {
        let at = place(point, size)
        switch phase {
        case .down: return [.mouseDown(at)]
        case .move: return [.mouseDragged(at)]
        case .up: return [.mouseUp(at)]
        }
    }

    /// A browser's wheel moves the view down for a positive `deltaY`; the
    /// window server scrolls content up for a positive one.
    func scroll(deltaX: Double, deltaY: Double) -> [HostEvent] {
        [.scroll(deltaX: -deltaX, deltaY: -deltaY)]
    }

    /// Each modifier down, the key down, held, up, then each modifier up in
    /// reverse — never one left latched. Nil when the Mac has no such key.
    func key(_ key: KeyboardKey, modifiers: Set<KeyModifier>, duration: Double) -> [HostEvent]? {
        guard key.hidUsage.page == 7, let code = MacKeyCode.of(usage: key.hidUsage.usage) else { return nil }
        let order = KeyModifier.allCases.filter(modifiers.contains)
        var held = Set<KeyModifier>()
        var events: [HostEvent] = order.map { modifier in
            held.insert(modifier)
            return .key(code: MacKeyCode.of(modifier), down: true, held: held)
        }
        events += [.key(code: code, down: true, held: held), .pause(duration), .key(code: code, down: false, held: held)]
        events += order.reversed().map { modifier in
            held.remove(modifier)
            return .key(code: MacKeyCode.of(modifier), down: false, held: held)
        }
        return events
    }

    /// The text in pieces a keyboard event carries, never splitting a character.
    func type(_ text: String) -> [HostEvent] {
        var pieces: [String] = []
        var piece = ""
        for character in text {
            if piece.utf16.count + character.utf16.count > Self.textPiece, !piece.isEmpty {
                pieces.append(piece)
                piece = ""
            }
            piece.append(character)
        }
        if !piece.isEmpty { pieces.append(piece) }
        return pieces.map(HostEvent.text)
    }

    private func place(_ point: Point, _ size: Size) -> Point {
        Point(x: bounds.origin.x + point.x / size.width * bounds.size.width,
              y: bounds.origin.y + point.y / size.height * bounds.size.height)
    }
}
