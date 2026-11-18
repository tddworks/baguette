import BaguetteDevice
import Foundation

/// Arguments a row hands to the command it invokes.
///
/// Deliberately opaque. baguette never interprets these — it carries
/// them from the plugin's own row, through the browser click, back to
/// the plugin's own command. Only the plugin that wrote them gives them
/// meaning, so modelling them as a typed shape would be baguette
/// inventing a schema for someone else's data.
///
/// Stored as canonical serialized JSON rather than `[String: Any]`,
/// which buys three things at once: `Sendable` (a dictionary of `Any`
/// isn't), `Equatable` by bytes, and the exact form that reaches the
/// command's stdin — so what a test compares is what a plugin receives.
struct PluginArgs: Equatable, Sendable {
    private let data: Data

    /// Nil when the object isn't representable as JSON — a plugin can
    /// only send what it could have printed.
    init?(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys]
        ) else { return nil }
        self.data = data
    }

    /// The arguments as a dictionary again, for handing to
    /// `JSONSerialization` when the context is assembled.
    var object: [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// Read one argument. Plugin-authored, so the value stays `Any` —
    /// the caller knows what it put there.
    subscript(key: String) -> Any? { object[key] }
}
