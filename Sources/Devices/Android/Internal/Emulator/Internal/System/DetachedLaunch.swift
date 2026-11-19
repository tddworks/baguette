import Foundation

/// Starts a tool that outlives baguette — an emulator keeps running after the
/// command that turned it on exits. Its output goes nowhere. Integration-only.
enum DetachedLaunch {
    static func run(_ tool: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
