import Foundation

/// Parses one stdin line as JSON, routes through `GestureRegistry`, and
/// dispatches the resulting `Gesture` against an `Input`. Returns a one-line
/// JSON ack the caller writes to stdout.
final class GestureDispatcher {
    private let input: any Input
    private let registry: GestureRegistry

    init(input: any Input, registry: GestureRegistry = .standard) {
        self.input = input
        self.registry = registry
    }

    func dispatch(line: String) -> String {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any]
        else {
            return ack(ok: false, error: "invalid JSON")
        }

        do {
            let gesture = try registry.parse(dict)
            return ack(ok: gesture.execute(on: input))
        } catch let error as GestureError {
            return ack(ok: false, error: error.message)
        } catch {
            return ack(ok: false, error: "\(error)")
        }
    }

    private func ack(ok: Bool, error: String? = nil) -> String {
        if let error {
            return "{\"ok\":\(ok),\"error\":\"\(error)\"}"
        }
        return "{\"ok\":\(ok)}"
    }
}
