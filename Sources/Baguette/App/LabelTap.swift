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

        guard case .found(let node) = found.lookup else {
            let refusal = found.refusal(of: name)
            return failure(refusal?.message ?? "nothing matches \(name)", refusal?.fields(affordances) ?? [:])
        }
        if envelope["touch"] as? Bool == true {
            return touch(node, envelope, screen: found.screen, accessibility, gesture, affordances, timing)
        }
        return press(node, envelope, screen: found.screen, accessibility, gesture, affordances, timing)
    }

    /// Presses, and touches when the press can't find the element. That's safe
    /// because nothing has happened yet; a press that was delivered is never followed
    /// by a touch, even if it seems to have done nothing.
    private static func press(
        _ node: AXNode, _ envelope: [String: Any], screen: AXScreen?, _ accessibility: any Accessibility,
        _ gesture: (String) -> String, _ affordances: AXAffordance.Style, _ timing: Timing
    ) -> String {
        let name = node.offerName
        let refused = failure("couldn't press \(name): it may have moved, so read the screen again")
        // The answer comes from here, so the fallback touch only needs to touch.
        var bare = envelope
        bare["then_describe_ui"] = nil
        let fallback = screen.flatMap { touchLine(node, bare, screen: $0) }
        var used: String?
        func act() -> Bool {
            if (try? accessibility.press(node)) == true { return true }
            guard let fallback else { return false }
            used = "touch"
            return gesture(fallback).contains(#""ok":true"#)
        }
        guard envelope["then_describe_ui"] as? Bool == true else {
            return act() ? tapped(#"{"ok":true}"#, name, used: used) : refused
        }
        let unchanged = "Nothing changed: \"\(name)\" may not respond, or the app acted without changing the screen. "
            + "Take a screenshot before tapping again, or try it with --touch."
        let result = ThenDescribe.perform(
            unchangedHint: unchanged, accessibility: accessibility, affordances: affordances, timing: timing.settle,
            act: act)
        return result.hasPrefix(#"{"ok":true"#) ? tapped(result, name, used: used) : refused
    }

    private static func touch(
        _ node: AXNode, _ envelope: [String: Any], screen: AXScreen?, _ accessibility: any Accessibility,
        _ gesture: (String) -> String, _ affordances: AXAffordance.Style, _ timing: Timing
    ) -> String {
        let name = node.offerName
        guard let screen, let line = touchLine(node, envelope, screen: screen) else {
            return failure("\(name) is off screen, where a finger can't reach: scroll to it first")
        }
        let result = ThenDescribe.dispatch(
            line: line, accessibility: accessibility, gesture: gesture, affordances: affordances, timing: timing.settle
        ) ?? gesture(line)
        return tapped(result, name)
    }

    /// The same request as a real touch, or `nil` when the element is off screen.
    private static func touchLine(_ node: AXNode, _ envelope: [String: Any], screen: AXScreen) -> String? {
        guard let point = node.touchPoint(on: screen) else { return nil }
        var touch = envelope
        touch["label"] = nil
        touch["touch"] = nil
        touch["x"] = point.x
        touch["y"] = point.y
        touch["width"] = screen.width
        touch["height"] = screen.height
        return (try? JSONSerialization.data(withJSONObject: touch)).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func tapped(_ result: String, _ name: String, used: String? = nil) -> String {
        let how = used.map { #","used":"\#($0)""# } ?? ""
        return result.replacingOccurrences(
            of: #"{"ok":true"#, with: #"{"ok":true,"tapped":"\#(GestureDispatcher.jsonEscape(name))"\#(how)"#,
            options: .anchored)
    }

    private static func failure(_ message: String, _ extra: [String: Any] = [:]) -> String {
        var fields: [String: Any] = ["ok": false, "error": message]
        extra.forEach { fields[$0.key] = $0.value }
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
