import Foundation

/// A tap that names its element. It presses through accessibility, which needs no
/// point on screen, so a blank spot on a row or a stale position can't miss. It isn't
/// a real finger, so `"touch":true` asks for one, for testing what a user can reach.
///
/// A tap that changes nothing is reported, never retried: the app may have acted
/// without changing its tree, and a second `Pay` could pay twice.
enum LabelTap {
    struct Timing: Equatable, Sendable {
        var find: TimeInterval = 5
        var poll: TimeInterval = 0.1
        var settle = AXSettle.Timing()
    }

    /// The result line for `{"type":"tap","label":…}`, else `nil`.
    static func dispatch(
        line: String,
        accessibility: any Accessibility,
        gesture: (String) -> String,
        affordances: AXAffordance.Style = .wire,
        timing: Timing = Timing()
    ) -> String? {
        guard let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let envelope = object as? [String: Any],
            envelope["type"] as? String == Tap.wireType,
            let name = envelope["label"] as? String
        else { return nil }

        let found = AXTarget.wait(
            for: name,
            glance: { try? accessibility.glance() },
            read: { try? accessibility.describeAll() },
            timeout: timing.find, poll: timing.poll)

        switch found.lookup {
        case .found(let node):
            if envelope["touch"] as? Bool == true {
                return touch(node, envelope, screen: found.screen, accessibility, gesture, affordances, timing)
            }
            return press(node, describing: envelope["then_describe_ui"] as? Bool == true, accessibility, affordances, timing)
        case .ambiguous(let nodes):
            return failure("more than one element matches \(name)", ["matches": nodes.map(\.offerName)])
        case .disabled(let node):
            return failure("\(node.offerName) is disabled")
        case .missing:
            return failure(
                "nothing matches \(name)",
                ["visible": found.tree.map(AXTarget.visibleNames) ?? []])
        }
    }

    private static func press(
        _ node: AXNode, describing: Bool, _ accessibility: any Accessibility,
        _ affordances: AXAffordance.Style, _ timing: Timing
    ) -> String {
        let name = node.offerName
        let refused = failure("couldn't press \(name): it may have moved, so read the screen again")
        guard describing else {
            return (try? accessibility.press(node)) == true ? tapped(#"{"ok":true}"#, name) : refused
        }
        let unchanged = "Nothing changed: \"\(name)\" may not respond, or the app acted without changing the screen. "
            + "Take a screenshot before tapping again."
        let result = ThenDescribe.perform(
            unchangedHint: unchanged, accessibility: accessibility, affordances: affordances, timing: timing.settle
        ) { (try? accessibility.press(node)) == true }
        return result.hasPrefix(#"{"ok":true"#) ? tapped(result, name) : refused
    }

    private static func touch(
        _ node: AXNode, _ envelope: [String: Any], screen: AXScreen?, _ accessibility: any Accessibility,
        _ gesture: (String) -> String, _ affordances: AXAffordance.Style, _ timing: Timing
    ) -> String {
        let name = node.offerName
        guard let screen, let point = node.touchPoint(on: screen) else {
            return failure("\(name) is off screen, where a finger can't reach: scroll to it first")
        }
        var touch = envelope
        touch["label"] = nil
        touch["touch"] = nil
        touch["x"] = point.x
        touch["y"] = point.y
        touch["width"] = screen.width
        touch["height"] = screen.height
        guard let bytes = try? JSONSerialization.data(withJSONObject: touch) else {
            return failure("could not build a touch for \(name)")
        }
        let line = String(decoding: bytes, as: UTF8.self)
        let result = ThenDescribe.dispatch(
            line: line, accessibility: accessibility, gesture: gesture, affordances: affordances, timing: timing.settle
        ) ?? gesture(line)
        return tapped(result, name)
    }

    private static func tapped(_ result: String, _ name: String) -> String {
        result.replacingOccurrences(
            of: #"{"ok":true"#, with: #"{"ok":true,"tapped":"\#(GestureDispatcher.jsonEscape(name))""#,
            options: .anchored)
    }

    private static func failure(_ message: String, _ extra: [String: [String]] = [:]) -> String {
        var fields: [String: Any] = ["ok": false, "error": message]
        extra.forEach { fields[$0.key] = $0.value }
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
