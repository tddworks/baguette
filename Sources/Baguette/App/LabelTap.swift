import Foundation

/// A tap that names its element instead of giving coordinates. It resolves
/// the name to a point, then goes through the same pipeline as any other tap.
///
/// A tap that changes nothing is reported, never retried: the app may have
/// acted without changing its tree, and a second `Pay` could pay twice.
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
            var envelope = object as? [String: Any],
            envelope["type"] as? String == Tap.wireType,
            let name = envelope["label"] as? String
        else { return nil }

        let found = AXTarget.wait(
            for: name,
            glance: { try? accessibility.glance() },
            read: { try? accessibility.describeAll() },
            timeout: timing.find, poll: timing.poll)

        switch found.lookup {
        case .tap(let node, let point):
            guard let screen = found.screen else {
                return failure("no screen size was observed for \(name)")
            }
            envelope["label"] = nil
            envelope["x"] = point.x
            envelope["y"] = point.y
            envelope["width"] = screen.width
            envelope["height"] = screen.height
            guard let bytes = try? JSONSerialization.data(withJSONObject: envelope) else {
                return failure("could not build a tap for \(name)")
            }
            let tap = String(decoding: bytes, as: UTF8.self)
            let result = ThenDescribe.dispatch(
                line: tap, accessibility: accessibility, gesture: gesture, affordances: affordances, timing: timing.settle
            ) ?? gesture(tap)
            let tapped = GestureDispatcher.jsonEscape(node.label ?? node.identifier ?? name)
            return result.replacingOccurrences(
                of: #"{"ok":true"#, with: #"{"ok":true,"tapped":"\#(tapped)""#,
                options: .anchored)
        case .ambiguous(let nodes):
            return failure("more than one element matches \(name)", ["matches": nodes.compactMap(\.label)])
        case .disabled(let node):
            return failure("\(node.label ?? name) is disabled")
        case .offScreen(let node):
            return failure("\(node.label ?? name) is off screen: scroll to it first")
        case .covered(let node):
            return failure("\(node.label ?? name) is under something else on screen: scroll to it first")
        case .missing:
            return failure(
                "nothing on screen matches \(name)",
                ["visible": found.tree.map(AXTarget.visibleNames) ?? []])
        }
    }

    private static func failure(_ message: String, _ extra: [String: [String]] = [:]) -> String {
        var fields: [String: Any] = ["ok": false, "error": message]
        extra.forEach { fields[$0.key] = $0.value }
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
