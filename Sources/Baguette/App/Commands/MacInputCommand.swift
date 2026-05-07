import ArgumentParser
import Foundation
import AppKit

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

        // Bring the target app to the foreground so the first gesture
        // doesn't race against whatever the user clicked last. We use
        // `NSRunningApplication.activate(...)` directly rather than
        // shelling out to `osascript` — settles focus reliably within
        // a single sleep window. Even with `postToPid` (which routes
        // events past system focus), tap coordinates only mean
        // anything once the target window is on top.
        if let running = NSRunningApplication(processIdentifier: app.pid) {
            running.activate(options: [.activateIgnoringOtherApps])
            // Give the WindowServer a beat to settle focus before the
            // first gesture lands.
            Thread.sleep(forTimeInterval: 0.2)
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
