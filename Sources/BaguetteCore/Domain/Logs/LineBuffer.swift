import Foundation

/// Streaming `\n`-delimited UTF-8 line splitter. Hands raw byte
/// chunks in, gets complete lines out, and holds any trailing
/// bytes past the last `\n` until the next append.
///
/// Used by `SimDeviceLogStream` to chop `xcrun simctl spawn`'s
/// stdout pipe into log entries. Lifted into its own value type
/// because the behaviour is pure data — testable without a spawn,
/// without a sim, and without the runtime juggling that the
/// adapter does for the SimulatorKit ObjC bridge.
///
/// Invalid-UTF8 line bytes are dropped silently rather than
/// surfaced as `nil`; callers that need byte-exact replay should
/// not use this type. For log streams, this is the right
/// trade-off — we'd rather skip a corrupted line than abort the
/// whole subscription.
struct LineBuffer {
    private(set) var leftover = Data()

    /// Append `bytes`, return any newly-completed lines (without
    /// the trailing `\n`), and stash anything past the last `\n`
    /// for the next append. An empty append yields no lines and
    /// leaves `leftover` untouched.
    mutating func append(_ bytes: Data) -> [String] {
        guard !bytes.isEmpty else { return [] }
        leftover.append(bytes)
        var lines: [String] = []
        while let nl = leftover.firstIndex(of: 0x0A) {
            let lineData = leftover.subdata(in: leftover.startIndex..<nl)
            leftover.removeSubrange(leftover.startIndex...nl)
            if let s = String(data: lineData, encoding: .utf8) {
                lines.append(s)
            }
        }
        return lines
    }
}
