import Foundation

/// A gesture that answers with what it did and the screen it left, so an
/// agent spends one call per screen: no guessed sleep, no separate read, and
/// a tap that changed nothing says so.
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
        let result = perform(accessibility: accessibility, timing: timing) {
            ack = gesture(line)
            return ack.contains(#""ok":true"#)
        }
        return ack.contains(#""ok":true"#) ? result : ack
    }

    /// The JSON for one gesture and the screen it left. `act` runs between
    /// looking at the screen and watching it settle.
    static func perform(
        action: String? = nil,
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
            let tree = outcome.tree?.json(affordances: affordances) ?? "null"
            return #"{"ok":true\#(named),"changed":\#(changed),"tree":\#(tree)}"#
        } catch {
            let message = GestureDispatcher.jsonEscape(error.localizedDescription)
            return #"{"ok":\#(acted)\#(named),"error":"\#(message)"}"#
        }
    }
}
