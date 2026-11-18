import Foundation

/// Intercepts `paste` wire lines ahead of `GestureDispatcher` on both
/// entry points — `baguette input` stdin and the serve stream WS —
/// the same way `describe_ui` is handled. Paste can't ride the
/// gesture registry: setting the pasteboard is an async host call
/// against `Pasteboard`, out of reach of the sync, `Input`-only
/// `Gesture.execute`.
enum PasteDispatch {
    enum Outcome: Equatable {
        /// The line isn't a paste envelope — the caller falls
        /// through to its gesture / reconfig pipeline.
        case notPaste
        case ok
        case failed(String)

        /// The stdin projection — one `{"ok":…}` line, matching the
        /// `GestureDispatcher` ack contract. `nil` for `notPaste`.
        var ackJSON: String? {
            switch self {
            case .notPaste: return nil
            case .ok: return #"{"ok":true}"#
            case .failed(let error):
                return "{\"ok\":false,\"error\":\"\(GestureDispatcher.jsonEscape(error))\"}"
            }
        }

        /// The WS projection — a typed frame the browser's
        /// `onStreamText` router can claim, like `describe_ui_result`.
        /// `nil` for `notPaste`.
        var resultFrame: String? {
            switch self {
            case .notPaste: return nil
            case .ok: return #"{"type":"paste_result","ok":true}"#
            case .failed(let error):
                return "{\"type\":\"paste_result\",\"ok\":false,\"error\":\"\(GestureDispatcher.jsonEscape(error))\"}"
            }
        }
    }

    /// Sniff `"type":"paste"`, parse, execute. `.notPaste` for every
    /// other line, including non-JSON — the caller's own pipeline
    /// owns those acks.
    static func dispatch(
        line: String, pasteboard: any Pasteboard, input: Abilities
    ) async -> Outcome {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              (dict["type"] as? String) == Paste.wireType
        else {
            return .notPaste
        }

        do {
            let paste = try Paste.parse(dict)
            let pressed = try await paste.execute(pasteboard: pasteboard, input: input)
            return pressed ? .ok : .failed("Cmd+V dispatch failed")
        } catch let error as GestureError {
            return .failed(error.message)
        } catch let error as PasteboardError {
            return .failed(error.description)
        } catch {
            return .failed("\(error)")
        }
    }
}
