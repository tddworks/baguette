import BaguetteDevice
import Foundation

/// A line `HingeControl` prints to its owner: its guest pid at startup, then
/// `done <status>` for each command once played. Any other line is
/// diagnostics. A pid of 1 or less is never a helper, so it is not a reply.
enum HingeControlReply: Equatable, Sendable {
    case pid(Int32)
    case done(Int32)

    init?(line: String) {
        let words = line.split(separator: " ", omittingEmptySubsequences: false)
        guard words.count == 2, let value = Int32(words[1]) else { return nil }
        switch words[0] {
        case "pid" where value > 1: self = .pid(value)
        case "done": self = .done(value)
        default: return nil
        }
    }
}

/// The replies in a helper's output, read as it arrives in chunks.
struct HingeControlReplyReader {
    private var lines = LineBuffer()

    mutating func append(_ bytes: Data) -> [HingeControlReply] {
        lines.append(bytes).compactMap(HingeControlReply.init(line:))
    }
}
