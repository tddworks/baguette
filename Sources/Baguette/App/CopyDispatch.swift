import BaguetteDevice
import Foundation

/// Intercepts `copy` wire lines ahead of `GestureDispatcher` on both
/// entry points — `baguette input` stdin and the serve stream WS —
/// the mirror of `PasteDispatch`. Where paste rides text *into* the
/// sim (pbcopy + Cmd+V), copy presses Cmd+C so the focused field
/// copies its selection, then ferries the sim's pasteboard *out* onto
/// the host Mac's clipboard (`simctl pbsync <udid> host`,
/// full-fidelity — images included). `press:false` skips the
/// keystroke for a pure ferry of whatever the sim already holds.
/// Can't ride the gesture registry: the sync is an async host call
/// against `Pasteboard`, out of reach of the sync, `Input`-only
/// `Gesture.execute`.
enum CopyDispatch {
    enum Outcome: Equatable {
        /// The line isn't a copy envelope — the caller falls through
        /// to its gesture / reconfig pipeline.
        case notCopy
        case ok
        case failed(String)

        /// The stdin projection — one `{"ok":…}` line, matching the
        /// `GestureDispatcher` ack contract. `nil` for `notCopy`.
        var ackJSON: String? {
            switch self {
            case .notCopy: return nil
            case .ok: return #"{"ok":true}"#
            case .failed(let error):
                return "{\"ok\":false,\"error\":\"\(GestureDispatcher.jsonEscape(error))\"}"
            }
        }

        /// The WS projection — a typed frame the browser's
        /// `onStreamText` router can claim, like `paste_result`.
        /// `nil` for `notCopy`.
        var resultFrame: String? {
            switch self {
            case .notCopy: return nil
            case .ok: return #"{"type":"copy_result","ok":true}"#
            case .failed(let error):
                return "{\"type\":\"copy_result\",\"ok\":false,\"error\":\"\(GestureDispatcher.jsonEscape(error))\"}"
            }
        }
    }

    /// Sniff `"type":"copy"`, press Cmd+C (unless `press:false`), then
    /// sync the sim's pasteboard onto the host. `.notCopy` for every
    /// other line, including non-JSON — the caller's own pipeline owns
    /// those acks.
    static func dispatch(
        line: String, pasteboard: any Pasteboard, input: Abilities
    ) async -> Outcome {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              (dict["type"] as? String) == "copy"
        else {
            return .notCopy
        }

        do {
            let copied = try await Copy.parse(dict)
                .execute(pasteboard: pasteboard, input: input)
            return copied ? .ok : .failed("Cmd+C dispatch failed")
        } catch let error as PasteboardError {
            return .failed(error.description)
        } catch {
            return .failed("\(error)")
        }
    }
}
