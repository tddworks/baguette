import ArgumentParser
import AppKit
import Foundation

/// `baguette mac logs --bundle-id <X> [--level …] [--style …] [--predicate …]`
///
/// Streams the macOS host's unified log filtered to the target app's
/// process, line-by-line on stdout, until SIGINT.
///
/// **Wrapper, not adapter** — the macOS host already ships a fully
/// capable `log stream` binary that takes any `NSPredicate`, so
/// there's nothing for `baguette` to add at the framework level.
/// What this command does add is the `--bundle-id` → `process == "Name"`
/// translation (and AND-composition with a user predicate), so the
/// agent doesn't have to look up the executable name.
///
/// On the iOS path we have to wrap because the simulator's `log`
/// binary is sandboxed and unsigned callers can't invoke it
/// directly — it goes through `xcrun simctl spawn <UDID> log stream`.
/// On macOS no such indirection is needed.
struct MacLogsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Stream a macOS app's unified-log entries to stdout"
    )

    @OptionGroup var target: MacAppOption

    @Option(help: "Minimum log level: default | info | debug (host `log stream` only accepts these three; for error/fault filtering use --predicate 'messageType == \"error\"')")
    var level: String = "info"

    @Option(help: "Output style: default | compact | json | ndjson | syslog")
    var style: String = "default"

    @Option(help: "Additional NSPredicate ANDed with the bundle-id filter")
    var predicate: String?

    func run() throws {
        let apps = RunningMacApps()
        guard let app = apps.find(bundleID: target.bundleId) else {
            log("App \(target.bundleId) not running")
            throw ExitCode.failure
        }

        // Resolve the executable's filename (sans extension) — that's
        // what `log stream`'s `process` field matches against.
        // `NSRunningApplication.executableURL` returns
        // `…/TextEdit.app/Contents/MacOS/TextEdit`, last path
        // component minus extension is `TextEdit`.
        guard let running = NSRunningApplication(processIdentifier: app.pid),
              let execURL = running.executableURL else {
            log("Could not resolve executable for pid=\(app.pid)")
            throw ExitCode.failure
        }
        let processName = execURL.deletingPathExtension().lastPathComponent

        // Build predicate: bundle-id filter, optionally ANDed with
        // a user-supplied predicate.
        let bundlePredicate = #"process == "\#(processName)""#
        let fullPredicate: String
        if let user = predicate, !user.isEmpty {
            fullPredicate = "(\(bundlePredicate)) AND (\(user))"
        } else {
            fullPredicate = bundlePredicate
        }

        // Shell out to /usr/bin/log. We don't pipe the output —
        // letting `log` write directly to our stdout means line-
        // buffering, paging, ANSI colour escapes (when applicable)
        // all just work.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        task.arguments = [
            "stream",
            "--predicate", fullPredicate,
            "--level", level,
            "--style", style,
        ]

        // SIGINT (Ctrl-C) propagates to the child process; install
        // an explicit handler so we exit 0 instead of 130 when the
        // user terminates the stream cleanly.
        signal(SIGINT, SIG_IGN)
        let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sigSource.setEventHandler {
            task.terminate()
        }
        sigSource.resume()

        do {
            try task.run()
        } catch {
            log("mac logs: failed to spawn /usr/bin/log: \(error)")
            throw ExitCode.failure
        }
        task.waitUntilExit()
    }
}
