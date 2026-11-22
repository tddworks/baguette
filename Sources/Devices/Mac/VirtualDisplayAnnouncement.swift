import Foundation

/// What a `baguette virtual-display` process says, once, on its own line: the
/// display it made — its `CGDirectDisplayID` and UUID — or why it made none.
enum VirtualDisplayAnnouncement: Equatable, Sendable {
    case ready(id: UInt32, uuid: String)
    case failed(String)

    /// The announcement a line carries; nil for any other line (a log line).
    init?(line: String) {
        let words = line.split(separator: " ", maxSplits: 2).map(String.init)
        switch words.first {
        case "ready":
            guard words.count == 3, let id = UInt32(words[1]), !words[2].isEmpty else { return nil }
            self = .ready(id: id, uuid: words[2])
        case "failed":
            self = .failed(words.dropFirst().joined(separator: " "))
        default:
            return nil
        }
    }

    /// The line the process says it in.
    var line: String {
        switch self {
        case let .ready(id, uuid): "ready \(id) \(uuid)"
        case let .failed(reason): "failed \(reason)"
        }
    }
}
