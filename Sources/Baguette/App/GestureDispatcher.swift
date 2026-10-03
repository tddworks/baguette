import Foundation

/// Parses one stdin line as JSON, routes through `GestureRegistry`, and
/// dispatches the resulting `Gesture` against an `Input`. Returns a one-line
/// JSON ack the caller writes to stdout.
///
/// `@unchecked` because `GestureRegistry` is a class with a mutating
/// `register` API. Both stored properties are `let`, `Input` is
/// `Sendable`, and a registry is only ever written while it is being
/// built (`GestureRegistry.standard`, or a test's own) — `dispatch`
/// reads it and nothing else. What crosses the isolation boundary is a
/// finished, frozen object.
final class GestureDispatcher: @unchecked Sendable {
    private let input: any Input
    private let registry: GestureRegistry
    private let screenGuard: InputScreenGuard?

    init(input: any Input, registry: GestureRegistry = .standard, screenGuard: InputScreenGuard? = nil) {
        self.input = input
        self.registry = registry
        self.screenGuard = screenGuard
    }

    func dispatch(line: String) -> String {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any]
        else {
            return ack(ok: false, error: "invalid JSON")
        }

        do {
            try screenGuard?.expected.validateEnvelope(dict)
            let gesture = try registry.parse(dict)
            let ok = gesture.execute(on: input)
            return ack(ok: ok, error: ok ? nil : screenGuard?.errorDescription)
        } catch let error as GestureError {
            return ack(ok: false, error: error.message)
        } catch let error as ExpectedScreen.Failure {
            return ack(ok: false, error: error.localizedDescription)
        } catch {
            return ack(ok: false, error: "\(error)")
        }
    }

    private func ack(ok: Bool, error: String? = nil) -> String {
        if let error {
            return "{\"ok\":\(ok),\"error\":\"\(Self.jsonEscape(error))\"}"
        }
        return "{\"ok\":\(ok)}"
    }

    static func jsonEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 8)
        for ch in s.unicodeScalars {
            switch ch {
            case "\"":  out.append("\\\"")
            case "\\":  out.append("\\\\")
            case "\n":  out.append("\\n")
            case "\r":  out.append("\\r")
            case "\t":  out.append("\\t")
            case "\u{08}": out.append("\\b")
            case "\u{0C}": out.append("\\f")
            default:
                if ch.value < 0x20 {
                    out.append(String(format: "\\u%04x", ch.value))
                } else {
                    out.append(Character(ch))
                }
            }
        }
        return out
    }
}
