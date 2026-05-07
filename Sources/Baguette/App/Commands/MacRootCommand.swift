import ArgumentParser

/// `baguette mac <subcommand>` — entry point for the native macOS
/// app target tree. Mirrors the iOS-simulator subcommands one-for-one
/// so `baguette tap --udid X …` and `baguette mac tap --bundle-id X …`
/// share identical flag shapes once Stage 2 input lands.
struct MacRootCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mac",
        abstract: "Drive native macOS apps (read-only in Stage 1)",
        subcommands: [
            MacListCommand.self,
            MacScreenshotCommand.self,
            MacDescribeUICommand.self,
            MacInputCommand.self,
        ]
    )
}

/// Reused by every mac subcommand that targets one specific app.
struct MacAppOption: ParsableArguments {
    @Option(name: .long, help: "Target app bundle ID (e.g. com.apple.TextEdit)")
    var bundleId: String
}
