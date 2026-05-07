import ArgumentParser

/// `baguette mac list [--json]` — list every running macOS app.
/// Mirrors `baguette list`; emits one JSON object per app per line
/// by default, or a single grouped envelope with `--json` matching
/// the `/mac.json` route's shape.
struct MacListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List running macOS apps"
    )

    @Flag(name: .long, help: "Emit one active/inactive JSON envelope (matches /mac.json)")
    var json: Bool = false

    func run() {
        let apps = RunningMacApps()
        if json {
            print(apps.listJSON)
        } else {
            for app in apps.all {
                print(app.json)
            }
        }
    }
}
