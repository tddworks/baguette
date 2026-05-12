import ArgumentParser

@main
struct Baguette: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "baguette",
        abstract: "Headless iOS simulator control",
        version: baguetteVersion,
        subcommands: [
            ListCommand.self,
            BootCommand.self,
            ShutdownCommand.self,
            InputCommand.self,
            StreamCommand.self,
            TapCommand.self,
            DoubleTapCommand.self,
            SwipeCommand.self,
            PinchCommand.self,
            PanCommand.self,
            PressCommand.self,
            KeyCommand.self,
            TypeCommand.self,
            ChromeCommand.self,
            ScreenshotCommand.self,
            DescribeUICommand.self,
            LogsCommand.self,
            ServeCommand.self,
            McpCommand.self,
            OrientationCommand.self,
            DiagDigitizerTrackpadCommand.self,
        ]
    )
}
