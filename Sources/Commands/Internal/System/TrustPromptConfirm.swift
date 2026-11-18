import Foundation

extension TrustPrompt {
    /// Ask on the terminal, and read the answer from stdin.
    static func confirm(_ message: String) -> Bool {
        print(message)
        print("Add it? [y/N] ", terminator: "")
        return accepts(readLine())
    }
}
