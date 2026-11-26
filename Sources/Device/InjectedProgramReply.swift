import Foundation

/// A line a serving program baguette runs in the guest prints to its owner
/// (`DeviceHubControls serve`, `HIDButtons serve`): its guest pid at startup,
/// then `done <status>` for each command once played. Any other line is
/// diagnostics. A pid of 1 or less is never a program, so it is not a reply.
public enum InjectedProgramReply: Equatable, Sendable {
    case pid(Int32)
    case done(Int32)

    public init?(line: String) {
        let words = line.split(separator: " ", omittingEmptySubsequences: false)
        guard words.count == 2, let value = Int32(words[1]) else { return nil }
        switch words[0] {
        case "pid" where value > 1: self = .pid(value)
        case "done": self = .done(value)
        default: return nil
        }
    }
}

/// The replies in a program's output, read as it arrives in chunks.
public struct InjectedProgramReplyReader {
    public init() {}

    private var lines = LineBuffer()

    public mutating func append(_ bytes: Data) -> [InjectedProgramReply] {
        lines.append(bytes).compactMap(InjectedProgramReply.init(line:))
    }
}

@available(*, deprecated, renamed: "InjectedProgramReply")
public typealias HingeControlReply = InjectedProgramReply

@available(*, deprecated, renamed: "InjectedProgramReplyReader")
public typealias HingeControlReplyReader = InjectedProgramReplyReader
