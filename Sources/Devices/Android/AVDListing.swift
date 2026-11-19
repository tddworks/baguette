import Foundation

/// What `emulator -list-avds` prints, read as the installed AVDs' names: one
/// per line, the emulator's own log lines (`INFO | …`) passed over.
enum AVDListing {
    static func names(in output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.isEmpty && !$0.contains(" ") && !$0.contains("|") }
    }
}
