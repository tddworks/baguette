import Foundation

/// A gesture that answers with what it did and the screen it left, so an
/// agent spends one call per screen: no guessed sleep, no separate read, and
/// a tap that changed nothing says so and offers what to try instead. That moment
/// costs an agent the most: left alone, it re-reads, retries the same point and
/// takes a screenshot, and baguette already knows the answer.
enum ThenDescribe {
    /// Ahead of the gesture pipeline on a `baguette input` session: the
    /// result line for an envelope with `"then_describe_ui":true`, else `nil`.
    static func dispatch(
        line: String,
        accessibility: any Accessibility,
        gesture: (String) -> String,
        timing: AXSettle.Timing = AXSettle.Timing()
    ) -> String? {
        guard let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dict = object as? [String: Any],
            dict["then_describe_ui"] as? Bool == true
        else { return nil }

        var ack = ""
        let point = (dict["x"] as? Double).flatMap { x in (dict["y"] as? Double).map { Point(x: x, y: $0) } }
        let result = perform(at: point, accessibility: accessibility, timing: timing) {
            ack = gesture(line)
            return ack.contains(#""ok":true"#)
        }
        return ack.contains(#""ok":true"#) ? result : ack
    }

    /// The JSON for one gesture and the screen it left. `act` runs between
    /// looking at the screen and watching it settle.
    static func perform(
        action: String? = nil,
        at point: Point? = nil,
        accessibility: any Accessibility,
        affordances: AXAffordance.Style = .wire,
        timing: AXSettle.Timing = AXSettle.Timing(),
        act: () -> Bool
    ) -> String {
        let named = action.map { #","action":"\#($0)""# } ?? ""
        var changed = false
        var acted = false
        do {
            let outcome = try AXSettle.run(
                act: { acted = act(); return acted },
                glance: { try? accessibility.glance() },
                read: { try accessibility.describeAll() },
                timing: timing)
            guard let outcome else { return #"{"ok":false\#(named)}"# }
            changed = outcome.changed
            guard let tree = outcome.tree else {
                return #"{"ok":true\#(named),"changed":\#(changed),"tree":null}"#
            }
            var guidance = ""
            if !changed, let point, let miss = tree.missedTap(at: point, style: affordances) {
                guidance = #","hint":"\#(GestureDispatcher.jsonEscape(miss.hint))""#
                if let next = miss.next { guidance += #","try":\#(AXAffordance.json(next))"# }
            }
            return #"{"ok":true\#(named),"changed":\#(changed)\#(guidance),"affordances":\#(tree.affordancesJSON(affordances)),"tree":\#(tree.json)}"#
        } catch {
            let message = GestureDispatcher.jsonEscape(error.localizedDescription)
            return #"{"ok":\#(acted)\#(named),"error":"\#(message)"}"#
        }
    }
}
