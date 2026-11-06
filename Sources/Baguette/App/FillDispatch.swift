import Foundation

/// Answers `fill` on a `baguette input` session and for `baguette fill`, ahead of the
/// gesture pipeline, the way `paste` is handled. The rules are `Fill`'s; this parses
/// a line and serializes the outcome.
enum FillDispatch {
    /// The result line, or `nil` when `line` isn't a fill and belongs to the caller's
    /// own pipeline.
    static func dispatch(
        line: String,
        accessibility: any Accessibility,
        pasteboard: any Pasteboard,
        input: any Input,
        timing: Fill.Timing = Fill.Timing(),
        inputTaken: @Sendable () async -> Bool = { false }
    ) async -> String? {
        guard let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dict = object as? [String: Any],
            dict["type"] as? String == Fill.wireType
        else { return nil }

        do {
            let fill = try Fill.parse(dict)
            let outcome = await fill.execute(
                accessibility: accessibility, pasteboard: pasteboard, input: input, timing: timing, inputTaken: inputTaken)
            return AXAffordance.json(outcome.answer)
        } catch let error as GestureError {
            return AXAffordance.json(["ok": false, "error": error.message])
        } catch {
            return AXAffordance.json(["ok": false, "error": "\(error)"])
        }
    }
}
