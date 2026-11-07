import Foundation

/// Answers `describe_ui` on a `baguette input` session, ahead of the
/// gesture pipeline. A long-lived process skips startup and the HID
/// warm-up, so one session can look and act at the speed a loop needs.
/// The frame matches the stream WebSocket's `describe_ui_result`.
enum DescribeUIDispatch {
    /// The result line, or `nil` when `line` is not a `describe_ui`
    /// envelope and belongs to the caller's own pipeline.
    static func dispatch(line: String, accessibility: any Accessibility) -> String? {
        guard let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dict = object as? [String: Any],
            (dict["type"] as? String) == "describe_ui"
        else { return nil }

        do {
            let read = try DescribeUI.parse(
                x: dict["x"] as? Double, y: dict["y"] as? Double, short: dict["short"] as? Bool == true)
            guard let node = try read.read(from: accessibility) else { return failure("no accessibility data") }
            return #"{"type":"describe_ui_result","ok":true,\#(read.wireFields(of: node))}"#
        } catch let refusal as DescribeUI.Refusal {
            return failure(refusal.message)
        } catch {
            return failure(error.localizedDescription)
        }
    }

    private static func failure(_ message: String) -> String {
        #"{"type":"describe_ui_result","ok":false,"error":"\#(GestureDispatcher.jsonEscape(message))"}"#
    }
}
