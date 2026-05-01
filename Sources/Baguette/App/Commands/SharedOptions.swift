import ArgumentParser

/// Reused by every subcommand that targets one specific simulator.
struct DeviceOption: ParsableArguments {
    @Option(name: .long, help: "Simulator UDID")
    var udid: String

    @Option(name: .long, help: "Custom device set path (defaults to Xcode's default set)")
    var deviceSet: String?
}
