import ArgumentParser
import Foundation

/// `baguette mac input --bundle-id <X>` — read newline-delimited
/// JSON gestures from stdin and dispatch them to the target macOS
/// app. Mirrors `baguette input` for the iOS path; both flow
/// through the same `GestureDispatcher`, so the wire envelopes are
/// identical (`tap`, `swipe`, `scroll`, `key`, `type` — see the
/// per-command Stage-2 scope notes in `CGEventInput`).
struct MacInputCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "input",
        abstract: "Read newline-delimited JSON gestures from stdin and post them to a macOS app"
    )

    @OptionGroup var target: MacAppOption

    func run() {
        let apps = RunningMacApps()
        guard let app = apps.find(bundleID: target.bundleId) else {
            log("App \(target.bundleId) not running")
            Foundation.exit(1)
        }
        let dispatcher = GestureDispatcher(input: app.input())
        log("Mac input session started for \(target.bundleId), reading from stdin")
        while let line = readLine() {
            print(dispatcher.dispatch(line: line))
            fflush(stdout)
        }
        log("stdin closed, mac input session ending")
    }
}
